import AppKit
import Metal
import SceneKit
import SimpleSKPCore
import simd

/// Offscreen Metal shadow-map & pattern atlas renderer for `VideoProjector` instances in `ViewportScene`.
/// Supports up to 4 simultaneous active projectors in a 2×2 atlas:
/// - `depthBuffer`: `2048 × 2048` `Float32` metric depth buffer (four `1024 × 1024` tiles storing linear eye-depth `z_e` in metres)
/// - `colorBuffer`: `1920 × 1200` `UInt32` RGBA8 atlas (four `960 × 600` 16:10 WUXGA tiles)
/// - `paramsBuffer`: packed `Float4` uniform buffer for SceneKit's `.surface` shader modifier
final class VideoProjectorRenderer: @unchecked Sendable {
    static let maxActiveProjectors = 4
    static let depthTileSize = 1024
    static let depthAtlasSize = depthTileSize * 2 // 2048 × 2048
    static let colorTileWidth = 960
    static let colorTileHeight = 600
    static let colorAtlasWidth = colorTileWidth * 2 // 1920
    static let colorAtlasHeight = colorTileHeight * 2 // 1200

    struct FaceChunkRef {
        var positions: MTLBuffer
        var indexBuffer: MTLBuffer
        var indexCount: Int
        var isVisible: () -> Bool
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private let depthPipeline: MTLRenderPipelineState?
    private let depthStencilState: MTLDepthStencilState?

    private var depthAtlasTexture: MTLTexture?
    private var hwDepthTexture: MTLTexture?
    private var colorAtlasTexture: MTLTexture?

    private(set) var depthProperty: SCNMaterialProperty?
    private(set) var colorProperty: SCNMaterialProperty?

    private var cachedPatternKeys: [Int: String] = [:]
    /// Cached 4-quadrant bounce tints (`0 = HG`, `1 = HD`, `2 = BG`, `3 = BD`) per projector slot,
    /// computed via QuestVR's 12×12 quadrant probe (`moyenne_quadrant_12x12`).
    private var cachedQuadrantTints: [Int: [SIMD3<Float>]] = [:]

    func quadrantBounceTint(forSlot slot: Int, quadrant: Int) -> SIMD3<Float> {
        guard let tints = cachedQuadrantTints[slot], quadrant >= 0, quadrant < tints.count else {
            return SIMD3<Float>(repeating: 0.5)
        }
        return tints[quadrant]
    }

    init(device: MTLDevice) {
        self.device = device
        self.commandQueue = device.makeCommandQueue()

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct ProjDepthOut {
            float4 position [[position]];
            float eyeDepth;
        };

        vertex ProjDepthOut sskp_projDepthVS(
            const device packed_float3 *positions [[buffer(0)]],
            constant float4x4 &viewProj [[buffer(1)]],
            uint vid [[vertex_id]]
        ) {
            ProjDepthOut out;
            float3 p = float3(positions[vid]);
            float4 clip = viewProj * float4(p, 1.0);
            out.position = clip;
            out.eyeDepth = clip.w;
            return out;
        }

        fragment float sskp_projDepthFS(ProjDepthOut in [[stage_in]]) {
            return in.eyeDepth;
        }
        """

        var pipeline: MTLRenderPipelineState? = nil
        if let library = try? device.makeLibrary(source: shaderSource, options: nil),
           let vs = library.makeFunction(name: "sskp_projDepthVS"),
           let fs = library.makeFunction(name: "sskp_projDepthFS") {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.colorAttachments[0].pixelFormat = .r32Float
            desc.depthAttachmentPixelFormat = .depth32Float
            pipeline = try? device.makeRenderPipelineState(descriptor: desc)
        }
        self.depthPipeline = pipeline

        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .less
        dsDesc.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: dsDesc)
    }

    private func ensureTexturesAllocated() {
        if depthAtlasTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r32Float,
                width: Self.depthAtlasSize,
                height: Self.depthAtlasSize,
                mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            if let tex = device.makeTexture(descriptor: desc) {
                depthAtlasTexture = tex
                let prop = SCNMaterialProperty(contents: tex)
                prop.minificationFilter = .nearest
                prop.magnificationFilter = .nearest
                prop.mipFilter = .none
                prop.wrapS = .clamp
                prop.wrapT = .clamp
                depthProperty = prop
            }
        }
        if hwDepthTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float,
                width: Self.depthAtlasSize,
                height: Self.depthAtlasSize,
                mipmapped: false
            )
            desc.usage = .renderTarget
            desc.storageMode = .private
            hwDepthTexture = device.makeTexture(descriptor: desc)
        }
        if colorAtlasTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: Self.colorAtlasWidth,
                height: Self.colorAtlasHeight,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            if let tex = device.makeTexture(descriptor: desc) {
                colorAtlasTexture = tex
                let prop = SCNMaterialProperty(contents: tex)
                prop.minificationFilter = .linear
                prop.magnificationFilter = .linear
                prop.mipFilter = .none
                prop.wrapS = .clamp
                prop.wrapT = .clamp
                colorProperty = prop
            }
        }
    }

    /// Updates the color pattern atlas and renders the offscreen metric shadow depth maps for `activeProjectors`.
    func update(
        activeProjectors: [VideoProjector],
        faceChunks: [FaceChunkRef],
        zNear: Float,
        zFar: Float
    ) {
        let count = min(activeProjectors.count, Self.maxActiveProjectors)
        guard count > 0 else { return }
        ensureTexturesAllocated()

        // 1. Update pattern tiles (only when a slot's pattern/spec/image changed)
        if let colorTex = colorAtlasTexture {
            for slot in 0..<count {
                let p = activeProjectors[slot]
                let key = "\(p.specID)|\(p.pattern.rawValue)|\(p.customImagePath ?? "")|\(String(format: "%.2f", p.throwRatio))|\(String(format: "%.2f", p.lensShiftH))|\(String(format: "%.2f", p.lensShiftV))"
                if cachedPatternKeys[slot] != key {
                    uploadPatternTile(for: p, slot: slot, into: colorTex)
                    cachedPatternKeys[slot] = key
                }
            }
        }

        // 2. Render metric shadow depth maps into `depthAtlasTexture`
        guard let commandQueue,
              let depthPipeline,
              let depthStencilState,
              let depthAtlasTexture,
              let hwDepthTexture,
              let cmdBuf = commandQueue.makeCommandBuffer()
        else { return }

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture = depthAtlasTexture
        rpDesc.colorAttachments[0].loadAction = .clear
        rpDesc.colorAttachments[0].clearColor = MTLClearColor(red: 1.0e9, green: 1.0e9, blue: 1.0e9, alpha: 1.0)
        rpDesc.colorAttachments[0].storeAction = .store

        rpDesc.depthAttachment.texture = hwDepthTexture
        rpDesc.depthAttachment.loadAction = .clear
        rpDesc.depthAttachment.clearDepth = 1.0
        rpDesc.depthAttachment.storeAction = .dontCare

        if let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpDesc) {
            encoder.setRenderPipelineState(depthPipeline)
            encoder.setDepthStencilState(depthStencilState)
            encoder.setCullMode(.none) // Architectural faces are double-sided; any triangle blocks the projector beam

            let tile = Self.depthTileSize
            let visibleChunks = faceChunks.filter { $0.indexCount >= 3 && $0.isVisible() }

            for slot in 0..<count {
                let projector = activeProjectors[slot]
                let col = slot % 2
                let row = slot / 2
                encoder.setViewport(MTLViewport(
                    originX: Double(col * tile),
                    originY: Double(row * tile),
                    width: Double(tile),
                    height: Double(tile),
                    znear: 0.0,
                    zfar: 1.0
                ))
                encoder.setScissorRect(MTLScissorRect(
                    x: col * tile,
                    y: row * tile,
                    width: tile,
                    height: tile
                ))
                var vp = projector.viewProjectionMatrix(zNear: zNear, zFar: zFar)
                encoder.setVertexBytes(&vp, length: MemoryLayout<simd_float4x4>.stride, index: 1)

                for chunk in visibleChunks {
                    encoder.setVertexBuffer(chunk.positions, offset: 0, index: 0)
                    encoder.drawIndexedPrimitives(
                        type: .triangle,
                        indexCount: chunk.indexCount,
                        indexType: .uint32,
                        indexBuffer: chunk.indexBuffer,
                        indexBufferOffset: 0
                    )
                }
            }
            encoder.endEncoding()
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }

    // MARK: - Pattern Generation & Upload

    private func uploadPatternTile(for projector: VideoProjector, slot: Int, into texture: MTLTexture) {
        let w = Self.colorTileWidth
        let h = Self.colorTileHeight
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress,
                  let ctx = CGContext(
                      data: baseAddress,
                      width: w,
                      height: h,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return }

            // Flip vertically so y = 0 is top-left (matching UV v = 0 at top)
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)

            drawPattern(for: projector, in: ctx, width: CGFloat(w), height: CGFloat(h))
        }

        let col = slot % 2
        let row = slot / 2
        let region = MTLRegionMake2D(col * w, row * h, w, h)
        pixels.withUnsafeBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return }
            texture.replace(region: region, mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: bytesPerRow)
        }
        cachedQuadrantTints[slot] = Self.computeQuadrantBounceTints(pixels: pixels, width: w, height: h)
    }

    /// Computes the 4 quadrant bounce tints (`0 = HG`, `1 = HD`, `2 = BG`, `3 = BD`) from an RGBA8 pattern tile
    /// using QuestVR Seine Musicale Auditorium's `moyenne_quadrant_12x12` probe (`sonde_rebond_ndi.gdshader`):
    /// - 4 overlapping quadrants (`0.04..0.56` and `0.44..0.96`) with a staggered 12×12 = 144-sample grid per quadrant
    /// - Chroma boost (`1.32`) and perceptual luma curve (`pow(luma, 0.72)`)
    private static func computeQuadrantBounceTints(pixels: [UInt8], width w: Int, height h: Int) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(4)
        let span: Float = 0.52
        for q in 0..<4 {
            let u0: Float = (q & 1) == 1 ? 0.44 : 0.04
            let v0: Float = (q >= 2) ? 0.44 : 0.04
            var sum = SIMD3<Float>.zero
            for iy in 0..<12 {
                let v = v0 + (Float(iy) + 0.5) * (span / 12.0)
                let decal: Float = (iy & 1) == 1 ? 0.009 : -0.009
                let py = min(max(Int(v * Float(h)), 0), h - 1)
                let rowOffset = py * w * 4
                for ix in 0..<12 {
                    let u = u0 + (Float(ix) + 0.5) * (span / 12.0) + decal
                    let px = min(max(Int(u * Float(w)), 0), w - 1)
                    let idx = rowOffset + px * 4
                    let r = Float(pixels[idx]) / 255.0
                    let g = Float(pixels[idx + 1]) / 255.0
                    let b = Float(pixels[idx + 2]) / 255.0
                    sum += SIMD3<Float>(r, g, b)
                }
            }
            let moy = sum * (1.0 / 144.0)
            let luma = simd_dot(moy, SIMD3<Float>(0.299, 0.587, 0.114))
            let chroma = simd_max(simd_mix(SIMD3<Float>(repeating: luma), moy, SIMD3<Float>(repeating: 1.32)), .zero)
            let lumaGalbe = pow(min(max(luma, 0.0), 1.0), 0.72)
            let teinte = luma > 0.0005 ? chroma * (lumaGalbe / luma) : .zero
            result.append(teinte)
        }
        return result
    }

    private func drawPattern(for projector: VideoProjector, in ctx: CGContext, width w: CGFloat, height h: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: w, height: h)

        switch projector.pattern {
        case .customImage:
            if let path = projector.customImagePath, !path.isEmpty,
               let nsImage = NSImage(contentsOfFile: path),
               let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                ctx.setFillColor(CGColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 1.0))
                ctx.fill(rect)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: h)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(cgImage, in: rect)
                ctx.restoreGState()
                ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.85))
                ctx.setLineWidth(2.5)
                ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))
                return
            }
            drawCalibrationGrid(for: projector, in: ctx, width: w, height: h)

        case .colorBars:
            drawColorBars(for: projector, in: ctx, width: w, height: h)

        case .whiteFrame:
            drawWhiteFrame(for: projector, in: ctx, width: w, height: h)

        case .testGrid:
            drawCalibrationGrid(for: projector, in: ctx, width: w, height: h)
        }
    }

    private func drawCalibrationGrid(for projector: VideoProjector, in ctx: CGContext, width w: CGFloat, height h: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.10, blue: 0.16, alpha: 1.0))
        ctx.fill(rect)

        let cols = 16
        let rows = 10
        let cellW = w / CGFloat(cols)
        let cellH = h / CGFloat(rows)
        for r in 0..<rows {
            for c in 0..<cols where (r + c).isMultiple(of: 2) {
                ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.15, blue: 0.23, alpha: 1.0))
                ctx.fill(CGRect(x: CGFloat(c) * cellW, y: CGFloat(r) * cellH, width: cellW, height: cellH))
            }
        }

        for c in 1..<cols {
            let x = CGFloat(c) * cellW
            let isMajor = c.isMultiple(of: 2)
            ctx.setStrokeColor(CGColor(
                srgbRed: isMajor ? 0.30 : 0.18,
                green: isMajor ? 0.65 : 0.38,
                blue: isMajor ? 0.85 : 0.52,
                alpha: 1.0
            ))
            ctx.setLineWidth(isMajor ? 2.0 : 1.0)
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: h))
            ctx.strokePath()
        }
        for r in 1..<rows {
            let y = CGFloat(r) * cellH
            let isMajor = r.isMultiple(of: 2)
            ctx.setStrokeColor(CGColor(
                srgbRed: isMajor ? 0.30 : 0.18,
                green: isMajor ? 0.65 : 0.38,
                blue: isMajor ? 0.85 : 0.52,
                alpha: 1.0
            ))
            ctx.setLineWidth(isMajor ? 2.0 : 1.0)
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: w, y: y))
            ctx.strokePath()
        }

        // Center optical crosshairs
        let cx = w * 0.5
        let cy = h * 0.5
        ctx.setStrokeColor(CGColor(srgbRed: 0.98, green: 0.78, blue: 0.20, alpha: 1.0))
        ctx.setLineWidth(2.5)
        ctx.move(to: CGPoint(x: 0, y: cy))
        ctx.addLine(to: CGPoint(x: w, y: cy))
        ctx.move(to: CGPoint(x: cx, y: 0))
        ctx.addLine(to: CGPoint(x: cx, y: h))
        ctx.strokePath()

        // Central geometry circle + aspect diamond
        let rMain = min(w, h) * 0.42
        let rInner = min(w, h) * 0.22
        ctx.setStrokeColor(CGColor(srgbRed: 0.96, green: 0.98, blue: 1.0, alpha: 0.95))
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: CGRect(x: cx - rMain, y: cy - rMain, width: rMain * 2, height: rMain * 2))
        ctx.strokeEllipse(in: CGRect(x: cx - rInner, y: cy - rInner, width: rInner * 2, height: rInner * 2))

        ctx.setStrokeColor(CGColor(srgbRed: 0.22, green: 0.92, blue: 0.65, alpha: 0.90))
        ctx.setLineWidth(2.0)
        ctx.move(to: CGPoint(x: cx, y: 8))
        ctx.addLine(to: CGPoint(x: w - 8, y: cy))
        ctx.addLine(to: CGPoint(x: cx, y: h - 8))
        ctx.addLine(to: CGPoint(x: 8, y: cy))
        ctx.closePath()
        ctx.strokePath()

        // Outer crisp white/cyan frame border
        ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        ctx.setLineWidth(6.0)
        ctx.stroke(rect.insetBy(dx: 3.0, dy: 3.0))
        ctx.setStrokeColor(CGColor(srgbRed: 0.15, green: 0.88, blue: 0.98, alpha: 1.0))
        ctx.setLineWidth(2.0)
        ctx.stroke(rect.insetBy(dx: 8.0, dy: 8.0))
    }

    private func drawColorBars(for projector: VideoProjector, in ctx: CGContext, width w: CGFloat, height h: CGFloat) {
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (0.92, 0.92, 0.92), // White
            (0.92, 0.92, 0.12), // Yellow
            (0.12, 0.92, 0.92), // Cyan
            (0.12, 0.92, 0.22), // Green
            (0.92, 0.15, 0.88), // Magenta
            (0.92, 0.15, 0.15), // Red
            (0.15, 0.28, 0.95), // Blue
        ]
        let barW = w / CGFloat(bars.count)
        let topH = h * 0.72
        for (i, rgb) in bars.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0))
            ctx.fill(CGRect(x: CGFloat(i) * barW, y: 0, width: ceil(barW), height: topH))
        }
        let steps = 10
        let stepW = w / CGFloat(steps)
        for i in 0..<steps {
            let v = CGFloat(i) / CGFloat(steps - 1)
            ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1.0))
            ctx.fill(CGRect(x: CGFloat(i) * stepW, y: topH, width: ceil(stepW), height: h - topH))
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setStrokeColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        ctx.setLineWidth(5.0)
        ctx.stroke(rect.insetBy(dx: 2.5, dy: 2.5))
    }

    private func drawWhiteFrame(for projector: VideoProjector, in ctx: CGContext, width w: CGFloat, height h: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.93, alpha: 1.0))
        ctx.fill(rect)
        let cx = w * 0.5, cy = h * 0.5
        ctx.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.65, blue: 0.92, alpha: 0.85))
        ctx.setLineWidth(2.5)
        ctx.move(to: CGPoint(x: cx - 50, y: cy))
        ctx.addLine(to: CGPoint(x: cx + 50, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - 50))
        ctx.addLine(to: CGPoint(x: cx, y: cy + 50))
        ctx.strokePath()
        ctx.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.88, blue: 0.96, alpha: 1.0))
        ctx.setLineWidth(7.0)
        ctx.stroke(rect.insetBy(dx: 3.5, dy: 3.5))
    }

    // MARK: - SceneKit Surface Shader Modifier

    static let surfaceShaderModifier = """
    #pragma arguments
    int sskp_projCount;
    float4x4 sskp_projVP0;
    float4x4 sskp_projVP1;
    float4x4 sskp_projVP2;
    float4x4 sskp_projVP3;
    float4 sskp_projPI0;
    float4 sskp_projPI1;
    float4 sskp_projPI2;
    float4 sskp_projPI3;
    float4x4 sskp_projBPos0;
    float4x4 sskp_projBPos1;
    float4x4 sskp_projBPos2;
    float4x4 sskp_projBPos3;
    float4x4 sskp_projBNorm0;
    float4x4 sskp_projBNorm1;
    float4x4 sskp_projBNorm2;
    float4x4 sskp_projBNorm3;
    float4x4 sskp_projBCol0;
    float4x4 sskp_projBCol1;
    float4x4 sskp_projBCol2;
    float4x4 sskp_projBCol3;
    texture2d<float, access::sample> sskp_projDepth;
    texture2d<float, access::sample> sskp_projColor;

    #pragma body
    _surface.emission.rgb = float3(0.0);
    if (sskp_projCount > 0) {
        float3 sskp_wPos = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
        float3 sskp_wNorm = normalize((scn_frame.inverseViewTransform * float4(_surface.geometryNormal, 0.0)).xyz);
        float3 sskp_wCam = scn_frame.inverseViewTransform[3].xyz;
        if (dot(sskp_wNorm, sskp_wCam - sskp_wPos) < 0.0) {
            sskp_wNorm = -sskp_wNorm;
        }
        // Convert world space (Y-up) back to modelRoot space (Z-up, rotated -pi/2 around X)
        float3 sskp_mPos = float3(sskp_wPos.x, -sskp_wPos.z, sskp_wPos.y);
        float3 sskp_mNorm = float3(sskp_wNorm.x, -sskp_wNorm.z, sskp_wNorm.y);
        float3 sskp_totalProj = float3(0.0);
        float3 sskp_totalRebond = float3(0.0);

        constexpr sampler sskp_depthSampler(coord::normalized, filter::nearest, address::clamp_to_edge);
        constexpr sampler sskp_colorSampler(coord::normalized, filter::linear, address::clamp_to_edge);

        for (int sskp_i = 0; sskp_i < 4; ++sskp_i) {
            if (sskp_i >= sskp_projCount) { break; }
            float4x4 sskp_vp = (sskp_i == 0) ? sskp_projVP0 : ((sskp_i == 1) ? sskp_projVP1 : ((sskp_i == 2) ? sskp_projVP2 : sskp_projVP3));
            float4 sskp_pi = (sskp_i == 0) ? sskp_projPI0 : ((sskp_i == 1) ? sskp_projPI1 : ((sskp_i == 2) ? sskp_projPI2 : sskp_projPI3));
            float sskp_intensity = sskp_pi.w;
            if (sskp_intensity <= 0.0001) { continue; }

            // 1. Indirect Light Reverberation (QuestVR Seine Musicale 4-Quadrant Bounce)
            float4x4 sskp_bPosMat = (sskp_i == 0) ? sskp_projBPos0 : ((sskp_i == 1) ? sskp_projBPos1 : ((sskp_i == 2) ? sskp_projBPos2 : sskp_projBPos3));
            float4x4 sskp_bNormMat = (sskp_i == 0) ? sskp_projBNorm0 : ((sskp_i == 1) ? sskp_projBNorm1 : ((sskp_i == 2) ? sskp_projBNorm2 : sskp_projBNorm3));
            float4x4 sskp_bColMat = (sskp_i == 0) ? sskp_projBCol0 : ((sskp_i == 1) ? sskp_projBCol1 : ((sskp_i == 2) ? sskp_projBCol2 : sskp_projBCol3));
            float3 sskp_projRebond = float3(0.0);
            for (int sskp_q = 0; sskp_q < 4; ++sskp_q) {
                float4 sskp_bp = sskp_bPosMat[sskp_q];
                float sskp_rad = sskp_bp.w;
                if (sskp_rad <= 0.05) { continue; }
                float3 sskp_bNorm = sskp_bNormMat[sskp_q].xyz;
                float3 sskp_bCol = sskp_bColMat[sskp_q].xyz;
                float3 sskp_versImpact = sskp_bp.xyz - sskp_mPos;
                float sskp_d2 = dot(sskp_versImpact, sskp_versImpact);
                float3 sskp_dir = sskp_versImpact * rsqrt(max(sskp_d2, 2.25));
                float sskp_prox = 1.0 / (1.0 + sskp_d2 / (sskp_rad * sskp_rad));
                float sskp_cosRecv = dot(sskp_mNorm, sskp_dir);
                float sskp_orient = smoothstep(-0.20, 0.15, sskp_cosRecv) * (0.50 + 0.50 * clamp(sskp_cosRecv * 0.5 + 0.5, 0.0, 1.0));
                float sskp_cosEmit = dot(-sskp_dir, sskp_bNorm);
                float sskp_hemi = smoothstep(0.03, 0.35, sskp_cosEmit) * (0.55 + 0.45 * clamp(sskp_cosEmit * 0.5 + 0.5, 0.0, 1.0));
                float sskp_roomEnv = 1.0 / (1.0 + sskp_d2 / (sskp_rad * sskp_rad * 3.5));
                float sskp_poids = mix(0.28 * sskp_roomEnv, 1.0, sskp_prox * sskp_orient) * sskp_hemi;
                sskp_projRebond += sskp_bCol * sskp_poids;
            }
            sskp_totalRebond += sskp_projRebond * 0.25;

            // 2. Direct Optical Frustum Projection & Depth-Map Occlusion
            float4 sskp_clip = sskp_vp * float4(sskp_mPos, 1.0);
            float sskp_w = sskp_clip.w;
            if (sskp_w <= 0.15) { continue; }

            float sskp_u = (sskp_clip.x / sskp_w) * 0.5 + 0.5;
            float sskp_v = 0.5 - (sskp_clip.y / sskp_w) * 0.5;
            if (sskp_u < 0.0 || sskp_u > 1.0 || sskp_v < 0.0 || sskp_v > 1.0) { continue; }

            float3 sskp_toProj = sskp_pi.xyz - sskp_mPos;
            float sskp_dist = max(length(sskp_toProj), 0.15);
            float3 sskp_L = sskp_toProj / sskp_dist;
            float sskp_ndotl = dot(sskp_mNorm, sskp_L);
            if (sskp_ndotl <= 0.01) { continue; }

            float2 sskp_tileOrigin = float2(float(sskp_i % 2), float(sskp_i / 2)) * 0.5;
            float2 sskp_uvClamped = clamp(float2(sskp_u, sskp_v), float2(0.001), float2(0.999));
            float2 sskp_atlasUV = sskp_tileOrigin + sskp_uvClamped * 0.5;

            float sskp_bias = max(0.02, 0.005 * sskp_w / max(sskp_ndotl, 0.12));
            float sskp_texel = 1.0 / 2048.0;
            float sskp_vis = 0.0;
            sskp_vis += (sskp_w <= sskp_projDepth.sample(sskp_depthSampler, sskp_atlasUV).r + sskp_bias) ? 1.0 : 0.0;
            sskp_vis += (sskp_w <= sskp_projDepth.sample(sskp_depthSampler, sskp_atlasUV + float2( sskp_texel, 0.0)).r + sskp_bias) ? 1.0 : 0.0;
            sskp_vis += (sskp_w <= sskp_projDepth.sample(sskp_depthSampler, sskp_atlasUV + float2(-sskp_texel, 0.0)).r + sskp_bias) ? 1.0 : 0.0;
            sskp_vis += (sskp_w <= sskp_projDepth.sample(sskp_depthSampler, sskp_atlasUV + float2(0.0,  sskp_texel)).r + sskp_bias) ? 1.0 : 0.0;
            sskp_vis += (sskp_w <= sskp_projDepth.sample(sskp_depthSampler, sskp_atlasUV + float2(0.0, -sskp_texel)).r + sskp_bias) ? 1.0 : 0.0;
            sskp_vis *= 0.2;
            if (sskp_vis <= 0.001) { continue; }

            // Incidence-angle luminous flux attenuation:
            // - Surface normal to beam (theta = 0 deg -> ndotl = 1.0) gives 100% optimal flux (sskp_inc = 1.0)
            // - Grazing incidence (theta -> 90 deg -> ndotl -> 0.0) attenuates smoothly to 0
            float sskp_tInc = clamp(sskp_ndotl / 0.16, 0.0, 1.0);
            float sskp_smoothGrazing = sskp_tInc * sskp_tInc * (3.0 - 2.0 * sskp_tInc);
            float sskp_inc = pow(sskp_ndotl, 1.35) * sskp_smoothGrazing;

            float3 sskp_img = sskp_projColor.sample(sskp_colorSampler, sskp_atlasUV).rgb;
            float3 sskp_albedo = mix(float3(1.0), _surface.diffuse.rgb, 0.30);
            sskp_totalProj += sskp_img * sskp_albedo * (sskp_intensity * sskp_vis * sskp_inc * 1.45);
        }
        // Soft Reinhard compression on accumulated indirect bounce (as in QuestVR rebond_video.gdshaderinc)
        sskp_totalRebond = sskp_totalRebond / (float3(1.0) + sskp_totalRebond * 0.45);
        float3 sskp_rebondAlbedo = mix(float3(0.32), _surface.diffuse.rgb, 0.68);
        _surface.emission.rgb = sskp_totalProj + sskp_rebondAlbedo * sskp_totalRebond;
    }
    """
}
