import AppKit
import Metal
import SceneKit
import SimpleSKPCore
import SimpleSKPVideoBridge
import simd

/// Offscreen Metal shadow-map & pattern atlas renderer for `VideoProjector` instances in `ViewportScene`.
/// Supports up to 12 simultaneous active projectors and stage lights in a 4×4 atlas:
/// - `depthBuffer`: `2048 × 2048` `Float32` metric depth buffer (sixteen `512 × 512` tiles storing linear eye-depth `z_e` in metres)
/// - `colorBuffer`: `2560 × 1600` `UInt32` RGBA8 atlas (sixteen `640 × 400` 16:10 tiles)
/// - `paramsBuffer`: packed `Float4` uniform buffer for SceneKit's `.surface` shader modifier
final class VideoProjectorRenderer: @unchecked Sendable {
    static let maxActiveProjectors = 12
    static let atlasGridCols = 4
    static let atlasGridRows = 4
    static let depthTileSize = 512
    static let depthAtlasSize = depthTileSize * atlasGridCols // 2048 × 2048
    static let colorTileWidth = 640
    static let colorTileHeight = 400
    static let colorAtlasWidth = colorTileWidth * atlasGridCols // 2560
    static let colorAtlasHeight = colorTileHeight * atlasGridRows // 1600
    static let paramTexWidth = 32
    static let paramTexHeight = 16

    struct FaceChunkRef {
        var positions: MTLBuffer
        var indexBuffer: MTLBuffer
        var indexCount: Int
        var boundsMin: SIMD3<Float> = SIMD3<Float>(repeating: -.infinity)
        var boundsMax: SIMD3<Float> = SIMD3<Float>(repeating: .infinity)
        var isVisible: () -> Bool
    }

    struct SlotDepthKey: Hashable {
        let poseKey: VideoProjector.OpticalPoseKey
        let sceneRevision: UInt64
        let zNearQuantized: Int32
        let zFarQuantized: Int32
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue?
    private let depthPipeline: MTLRenderPipelineState?
    private let clearDepthTilePipeline: MTLRenderPipelineState?
    private let blitTilePipeline: MTLRenderPipelineState?
    private let depthStencilState: MTLDepthStencilState?
    private let noDepthWriteStencilState: MTLDepthStencilState?

    private var depthAtlasTexture: MTLTexture?
    private var hwDepthTexture: MTLTexture?
    private var colorAtlasTexture: MTLTexture?
    private var paramAtlasTexture: MTLTexture?

    private(set) var depthProperty: SCNMaterialProperty?
    private(set) var colorProperty: SCNMaterialProperty?
    private(set) var paramProperty: SCNMaterialProperty?

    private var cachedPatternKeys: [Int: String] = [:]
    private var cachedSlotDepthKeys: [Int: SlotDepthKey] = [:]
    private(set) var depthRenderPassCount: Int = 0
    private(set) var depthSlotRenderCount: Int = 0
    /// Cached 4-quadrant bounce tints (`0 = HG`, `1 = HD`, `2 = BG`, `3 = BD`) per projector slot,
    /// computed via QuestVR's 12×12 quadrant probe (`moyenne_quadrant_12x12`).
    private var cachedQuadrantTints: [Int: [SIMD3<Float>]] = [:]

    /// Active Syphon & NDI live stream clients keyed by projector slot (`0..<4`).
    private var syphonClients: [Int: SSKPVideoSyphonClient] = [:]
    private var ndiReceivers: [Int: SSKPVideoNDIReceiver] = [:]
    private var cachedLiveFrameRevisions: [Int: UInt64] = [:]
    private let notifyLock = NSLock()
    private var liveFrameNotificationPending = false

    /// Called on the main queue whenever a subscribed Syphon or NDI stream delivers a new video frame.
    var onNewLiveFrame: (() -> Void)?

    func quadrantBounceTint(forSlot slot: Int, quadrant: Int, projector: VideoProjector? = nil) -> SIMD3<Float> {
        let q = min(max(quadrant, 0), 3)
        if let p = projector {
            let horizOpen: Float = (q & 1) == 0
                ? simd_clamp((0.5 - p.shutterLeft) * 2.0, 0.0, 1.0)
                : simd_clamp((0.5 - p.shutterRight) * 2.0, 0.0, 1.0)
            let vertOpen: Float = (q < 2)
                ? simd_clamp((0.5 - p.shutterTop) * 2.0, 0.0, 1.0)
                : simd_clamp((0.5 - p.shutterBottom) * 2.0, 0.0, 1.0)
            let shutterFactor = horizOpen * vertOpen
            let beamRGB = p.effectiveBeamRGB

            if p.isStageLight {
                // Analytical O(1) quadrant bounce tint for RGB/RGBW stage lights (zero CPU bitmap generation!)
                let profileFill: Float = (p.spec.kind == .washPanel) ? 0.72 : 0.78
                let moy = beamRGB * (profileFill * shutterFactor)
                let luma = simd_dot(moy, SIMD3<Float>(0.299, 0.587, 0.114))
                let chroma = simd_max(simd_mix(SIMD3<Float>(repeating: luma), moy, SIMD3<Float>(repeating: 1.32)), .zero)
                let lumaGalbe = pow(min(max(luma, 0.0), 1.0), 0.72)
                return luma > 0.0005 ? chroma * (lumaGalbe / luma) : .zero
            } else {
                let baseTint: SIMD3<Float>
                if let tints = cachedQuadrantTints[slot], q < tints.count {
                    baseTint = tints[q]
                } else {
                    baseTint = SIMD3<Float>(repeating: 0.5)
                }
                return baseTint * beamRGB * shutterFactor
            }
        }
        guard let tints = cachedQuadrantTints[slot], q < tints.count else {
            return SIMD3<Float>(repeating: 0.5)
        }
        return tints[q]
    }

    deinit {
        stopAllLiveClients()
    }

    func stopAllLiveClients() {
        for client in syphonClients.values {
            client.stop()
        }
        syphonClients.removeAll()
        for receiver in ndiReceivers.values {
            receiver.stop()
        }
        ndiReceivers.removeAll()
        cachedLiveFrameRevisions.removeAll()
    }

    private func scheduleLiveFrameNotification() {
        notifyLock.lock()
        if liveFrameNotificationPending {
            notifyLock.unlock()
            return
        }
        liveFrameNotificationPending = true
        notifyLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyLock.lock()
            self.liveFrameNotificationPending = false
            self.notifyLock.unlock()
            self.onNewLiveFrame?()
        }
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

        struct ProjBlitOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex ProjBlitOut sskp_projBlitVS(
            constant uint &flipY [[buffer(0)]],
            uint vid [[vertex_id]]
        ) {
            float2 pos[3] = {
                float2(-1.0, -1.0),
                float2( 3.0, -1.0),
                float2(-1.0,  3.0)
            };
            float2 p = pos[vid];
            ProjBlitOut out;
            out.position = float4(p, 0.0, 1.0);
            float u = 0.5 * (p.x + 1.0);
            float vTop = 0.5 * (1.0 - p.y);
            out.uv = float2(u, (flipY != 0u) ? (1.0 - vTop) : vTop);
            return out;
        }

        fragment float4 sskp_projBlitFS(
            ProjBlitOut in [[stage_in]],
            texture2d<float, access::sample> srcTex [[texture(0)]]
        ) {
            constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
            float4 c = srcTex.sample(s, in.uv);
            return float4(c.rgb, 1.0);
        }

        fragment float sskp_projClearDepthFS(ProjBlitOut in [[stage_in]]) {
            return 1.0e9;
        }
        """

        var pipeline: MTLRenderPipelineState? = nil
        var clearPipeline: MTLRenderPipelineState? = nil
        var blitPipeline: MTLRenderPipelineState? = nil
        if let library = try? device.makeLibrary(source: shaderSource, options: nil) {
            if let vs = library.makeFunction(name: "sskp_projDepthVS"),
               let fs = library.makeFunction(name: "sskp_projDepthFS") {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vs
                desc.fragmentFunction = fs
                desc.colorAttachments[0].pixelFormat = .r32Float
                desc.depthAttachmentPixelFormat = .depth32Float
                pipeline = try? device.makeRenderPipelineState(descriptor: desc)
            }
            if let bvs = library.makeFunction(name: "sskp_projBlitVS"),
               let cfs = library.makeFunction(name: "sskp_projClearDepthFS") {
                let cdesc = MTLRenderPipelineDescriptor()
                cdesc.vertexFunction = bvs
                cdesc.fragmentFunction = cfs
                cdesc.colorAttachments[0].pixelFormat = .r32Float
                cdesc.depthAttachmentPixelFormat = .depth32Float
                clearPipeline = try? device.makeRenderPipelineState(descriptor: cdesc)
            }
            if let bvs = library.makeFunction(name: "sskp_projBlitVS"),
               let bfs = library.makeFunction(name: "sskp_projBlitFS") {
                let bdesc = MTLRenderPipelineDescriptor()
                bdesc.vertexFunction = bvs
                bdesc.fragmentFunction = bfs
                bdesc.colorAttachments[0].pixelFormat = .rgba8Unorm
                blitPipeline = try? device.makeRenderPipelineState(descriptor: bdesc)
            }
        }
        self.depthPipeline = pipeline
        self.clearDepthTilePipeline = clearPipeline
        self.blitTilePipeline = blitPipeline

        let dsDesc = MTLDepthStencilDescriptor()
        dsDesc.depthCompareFunction = .less
        dsDesc.isDepthWriteEnabled = true
        self.depthStencilState = device.makeDepthStencilState(descriptor: dsDesc)

        let noWriteDesc = MTLDepthStencilDescriptor()
        noWriteDesc.depthCompareFunction = .always
        noWriteDesc.isDepthWriteEnabled = false
        self.noDepthWriteStencilState = device.makeDepthStencilState(descriptor: noWriteDesc)
    }

    func invalidateDepthCache() {
        cachedSlotDepthKeys.removeAll()
    }

    private static func chunkIntersectsFrustum(
        boundsMin lo: SIMD3<Float>,
        boundsMax hi: SIMD3<Float>,
        viewProj vp: simd_float4x4,
        zNear: Float,
        zFar: Float
    ) -> Bool {
        guard lo.x <= hi.x else { return true }
        let corners: [SIMD3<Float>] = [
            SIMD3(lo.x, lo.y, lo.z),
            SIMD3(hi.x, lo.y, lo.z),
            SIMD3(lo.x, hi.y, lo.z),
            SIMD3(hi.x, hi.y, lo.z),
            SIMD3(lo.x, lo.y, hi.z),
            SIMD3(hi.x, lo.y, hi.z),
            SIMD3(lo.x, hi.y, hi.z),
            SIMD3(hi.x, hi.y, hi.z),
        ]
        var allLeft = true, allRight = true
        var allBottom = true, allTop = true
        var allNear = true, allFar = true
        for c in corners {
            let clip = vp * SIMD4<Float>(c, 1.0)
            let w = clip.w
            if clip.x >= -w { allLeft = false }
            if clip.x <=  w { allRight = false }
            if clip.y >= -w { allBottom = false }
            if clip.y <=  w { allTop = false }
            if w >= zNear   { allNear = false }
            if w <= zFar    { allFar = false }
        }
        return !(allLeft || allRight || allBottom || allTop || allNear || allFar)
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
            desc.usage = [.renderTarget, .shaderRead]
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
        if paramAtlasTexture == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float,
                width: Self.paramTexWidth,
                height: Self.paramTexHeight,
                mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .shared
            if let tex = device.makeTexture(descriptor: desc) {
                paramAtlasTexture = tex
                let prop = SCNMaterialProperty(contents: tex)
                prop.minificationFilter = .nearest
                prop.magnificationFilter = .nearest
                prop.mipFilter = .none
                prop.wrapS = .clamp
                prop.wrapT = .clamp
                paramProperty = prop
            }
        }
    }

    /// Uploads per-projector optical matrices, photometric parameters, and 4-quadrant bounce matrices into `paramAtlasTexture`.
    func updateParamTexture(
        activeProjectors: [VideoProjector],
        zNear: Float,
        zFar: Float,
        photometricSimulation: Bool,
        photometricReferenceLux: Float,
        bounceMatrices: [(bPos: simd_float4x4, bNorm: simd_float4x4, bCol: simd_float4x4)]
    ) {
        ensureTexturesAllocated()
        guard let paramTex = paramAtlasTexture else { return }
        let w = Self.paramTexWidth
        let h = Self.paramTexHeight
        var texels = [SIMD4<Float>](repeating: .zero, count: w * h)
        let count = min(activeProjectors.count, Self.maxActiveProjectors)
        let refLux: Float = photometricSimulation ? photometricReferenceLux : 0.0

        for i in 0..<count {
            let p = activeProjectors[i]
            let rowBase = i * w
            let vp = p.viewProjectionMatrix(zNear: zNear, zFar: zFar)
            texels[rowBase + 0] = vp.columns.0
            texels[rowBase + 1] = vp.columns.1
            texels[rowBase + 2] = vp.columns.2
            texels[rowBase + 3] = vp.columns.3
            texels[rowBase + 4] = SIMD4<Float>(p.position.x, p.position.y, p.position.z, p.intensity)
            texels[rowBase + 5] = SIMD4<Float>(p.effectiveLumens, p.throwRatio, p.spec.aspectRatio, refLux)
            if i < bounceMatrices.count {
                let b = bounceMatrices[i]
                texels[rowBase + 6]  = b.bPos.columns.0
                texels[rowBase + 7]  = b.bPos.columns.1
                texels[rowBase + 8]  = b.bPos.columns.2
                texels[rowBase + 9]  = b.bPos.columns.3
                texels[rowBase + 10] = b.bNorm.columns.0
                texels[rowBase + 11] = b.bNorm.columns.1
                texels[rowBase + 12] = b.bNorm.columns.2
                texels[rowBase + 13] = b.bNorm.columns.3
                texels[rowBase + 14] = b.bCol.columns.0
                texels[rowBase + 15] = b.bCol.columns.1
                texels[rowBase + 16] = b.bCol.columns.2
                texels[rowBase + 17] = b.bCol.columns.3
            }
            let beamRGB = p.effectiveBeamRGB
            texels[rowBase + 18] = SIMD4<Float>(beamRGB.x, beamRGB.y, beamRGB.z, p.whiteChannel)
            texels[rowBase + 19] = SIMD4<Float>(p.shutterLeft, p.shutterRight, p.shutterTop, p.shutterBottom)
            let kindCode: Float
            if p.isStageLight {
                kindCode = (p.spec.kind == .washPanel) ? 2.0 : 1.0
            } else {
                kindCode = 0.0
            }
            texels[rowBase + 20] = SIMD4<Float>(kindCode, p.edgeSoftness, 0.0, 0.0)
        }

        texels.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            paramTex.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: w * MemoryLayout<SIMD4<Float>>.stride
            )
        }
    }

    /// Fast single-slot update of the 4-quadrant bounce color columns (`x = 14..17`) in `paramAtlasTexture` when a live Syphon/NDI frame arrives.
    func updateSlotBounceColor(slot: Int, bCol: simd_float4x4) {
        guard slot >= 0, slot < Self.maxActiveProjectors, let paramTex = paramAtlasTexture else { return }
        let cols: [SIMD4<Float>] = [bCol.columns.0, bCol.columns.1, bCol.columns.2, bCol.columns.3]
        cols.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            paramTex.replace(
                region: MTLRegionMake2D(14, slot, 4, 1),
                mipmapLevel: 0,
                withBytes: base,
                bytesPerRow: 4 * MemoryLayout<SIMD4<Float>>.stride
            )
        }
    }

    /// Updates the color pattern atlas and renders the offscreen metric shadow depth maps for `activeProjectors`.
    /// Only projector slots whose optical pose or visible scene geometry changed since the last update are re-rendered.
    func update(
        activeProjectors: [VideoProjector],
        faceChunks: [FaceChunkRef],
        zNear: Float,
        zFar: Float,
        sceneRevision: UInt64 = 0
    ) {
        let t0 = CACurrentMediaTime()
        defer { FrameProfiler.shared.recordDuration(seconds: CACurrentMediaTime() - t0, for: "vp.depthMap") }
        let count = min(activeProjectors.count, Self.maxActiveProjectors)
        pruneInactiveLiveClients(activeProjectors: Array(activeProjectors.prefix(count)))
        for slot in count..<Self.maxActiveProjectors {
            cachedSlotDepthKeys.removeValue(forKey: slot)
        }
        guard count > 0 else { return }
        ensureTexturesAllocated()

        // 1. Update pattern or live video tiles (Stage lights are evaluated 100% analytically on the GPU -> 0 CPU rasterization!)
        if let colorTex = colorAtlasTexture {
            for slot in 0..<count {
                let p = activeProjectors[slot]
                if p.isStageLight {
                    continue
                }
                if p.pattern == .syphon || p.pattern == .ndi {
                    let key = "\(p.specID)|\(p.pattern.rawValue)|\(p.liveSourceID ?? "")|\(p.liveSourceName ?? "")"
                    let keyChanged = (cachedPatternKeys[slot] != key)
                    if keyChanged {
                        cachedPatternKeys[slot] = key
                        cachedLiveFrameRevisions[slot] = nil
                    }
                    _ = updateLiveVideoSlot(for: p, slot: slot, into: colorTex, forceFallbackIfDisconnected: keyChanged)
                } else {
                    let key = "\(p.specID)|\(p.pattern.rawValue)|\(p.customImagePath ?? "")"
                    if cachedPatternKeys[slot] != key {
                        uploadPatternTile(for: p, slot: slot, into: colorTex)
                        cachedPatternKeys[slot] = key
                    }
                }
            }
        }

        // 2. Determine which projector slots actually changed optical pose or visible geometry
        let zNearQ = Int32((zNear * 1000.0).rounded())
        let zFarQ = Int32((zFar * 10.0).rounded())
        var dirtySlots: [Int] = []
        for slot in 0..<count {
            let key = SlotDepthKey(
                poseKey: activeProjectors[slot].opticalPoseKey,
                sceneRevision: sceneRevision,
                zNearQuantized: zNearQ,
                zFarQuantized: zFarQ
            )
            if cachedSlotDepthKeys[slot] != key {
                dirtySlots.append(slot)
                cachedSlotDepthKeys[slot] = key
            }
        }

        // Fast path: if no projector moved and visible layers did not change, reuse the existing `depthAtlasTexture`!
        guard !dirtySlots.isEmpty else { return }

        // 3. Render metric shadow depth maps into `depthAtlasTexture` only for `dirtySlots`
        guard let commandQueue,
              let depthPipeline,
              let depthStencilState,
              let depthAtlasTexture,
              let hwDepthTexture,
              let cmdBuf = commandQueue.makeCommandBuffer()
        else { return }

        let canClearIndividualTiles = (clearDepthTilePipeline != nil && noDepthWriteStencilState != nil)
        let slotsToRender = (dirtySlots.count < count && canClearIndividualTiles) ? dirtySlots : Array(0..<count)
        let clearEntireAtlas = (slotsToRender.count == count)

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture = depthAtlasTexture
        rpDesc.colorAttachments[0].loadAction = clearEntireAtlas ? .clear : .load
        rpDesc.colorAttachments[0].clearColor = MTLClearColor(red: 1.0e9, green: 1.0e9, blue: 1.0e9, alpha: 1.0)
        rpDesc.colorAttachments[0].storeAction = .store

        rpDesc.depthAttachment.texture = hwDepthTexture
        rpDesc.depthAttachment.loadAction = .clear
        rpDesc.depthAttachment.clearDepth = 1.0
        rpDesc.depthAttachment.storeAction = .dontCare

        if let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpDesc) {
            encoder.setCullMode(.none) // Architectural faces are double-sided; any triangle blocks the projector beam

            let tile = Self.depthTileSize
            let visibleChunks = faceChunks.filter { $0.indexCount >= 3 && $0.isVisible() }

            for slot in slotsToRender {
                let projector = activeProjectors[slot]
                let col = slot % Self.atlasGridCols
                let row = slot / Self.atlasGridCols
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

                if !clearEntireAtlas,
                   let clearDepthTilePipeline,
                   let noDepthWriteStencilState {
                    encoder.setRenderPipelineState(clearDepthTilePipeline)
                    encoder.setDepthStencilState(noDepthWriteStencilState)
                    var flipFlag: UInt32 = 0
                    encoder.setVertexBytes(&flipFlag, length: MemoryLayout<UInt32>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }

                encoder.setRenderPipelineState(depthPipeline)
                encoder.setDepthStencilState(depthStencilState)
                var vp = projector.viewProjectionMatrix(zNear: zNear, zFar: zFar)
                encoder.setVertexBytes(&vp, length: MemoryLayout<simd_float4x4>.stride, index: 1)

                for chunk in visibleChunks {
                    guard Self.chunkIntersectsFrustum(
                        boundsMin: chunk.boundsMin,
                        boundsMax: chunk.boundsMax,
                        viewProj: vp,
                        zNear: zNear,
                        zFar: zFar
                    ) else { continue }
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

        depthRenderPassCount += 1
        depthSlotRenderCount += slotsToRender.count
        cmdBuf.commit()
    }

    /// Lightweight live-stream-only update called when a Syphon or NDI frame arrives while scene geometry is static.
    /// Returns the set of projector slot indices (`0..<4`) whose color tile and 4-quadrant bounce tints were updated.
    func updateLiveFramesOnly(activeProjectors: [VideoProjector]) -> Set<Int> {
        let t0 = CACurrentMediaTime()
        defer { FrameProfiler.shared.recordDuration(seconds: CACurrentMediaTime() - t0, for: "vp.liveVideo") }
        let count = min(activeProjectors.count, Self.maxActiveProjectors)
        pruneInactiveLiveClients(activeProjectors: Array(activeProjectors.prefix(count)))
        guard count > 0, let colorTex = colorAtlasTexture else { return [] }
        var updatedSlots = Set<Int>()
        for slot in 0..<count {
            let p = activeProjectors[slot]
            guard p.pattern == .syphon || p.pattern == .ndi else { continue }
            if updateLiveVideoSlot(for: p, slot: slot, into: colorTex, forceFallbackIfDisconnected: false) {
                updatedSlots.insert(slot)
            }
        }
        return updatedSlots
    }

    private func pruneInactiveLiveClients(activeProjectors: [VideoProjector]) {
        let count = activeProjectors.count
        for slot in 0..<Self.maxActiveProjectors {
            if slot >= count {
                if let c = syphonClients.removeValue(forKey: slot) { c.stop() }
                if let r = ndiReceivers.removeValue(forKey: slot) { r.stop() }
                cachedLiveFrameRevisions.removeValue(forKey: slot)
                continue
            }
            let p = activeProjectors[slot]
            if p.pattern != .syphon, let c = syphonClients.removeValue(forKey: slot) {
                c.stop()
                cachedLiveFrameRevisions.removeValue(forKey: slot)
            }
            if p.pattern != .ndi, let r = ndiReceivers.removeValue(forKey: slot) {
                r.stop()
                cachedLiveFrameRevisions.removeValue(forKey: slot)
            }
        }
    }

    private func updateLiveVideoSlot(
        for projector: VideoProjector,
        slot: Int,
        into atlasTexture: MTLTexture,
        forceFallbackIfDisconnected: Bool
    ) -> Bool {
        switch projector.pattern {
        case .syphon:
            guard let resolved = LiveVideoSourceManager.shared.resolveSyphonDescriptor(
                id: projector.liveSourceID,
                name: projector.liveSourceName
            ) else {
                if let existing = syphonClients.removeValue(forKey: slot) {
                    existing.stop()
                }
                if forceFallbackIfDisconnected || cachedQuadrantTints[slot] == nil {
                    uploadPatternTile(for: projector, slot: slot, into: atlasTexture)
                    return true
                }
                return false
            }

            if let existing = syphonClients[slot],
               existing.sourceIdentifier != resolved.identifier || !existing.isValid {
                existing.stop()
                syphonClients.removeValue(forKey: slot)
                cachedLiveFrameRevisions.removeValue(forKey: slot)
            }

            if syphonClients[slot] == nil {
                if let client = SSKPVideoSyphonClient(
                    serverDescription: resolved.description,
                    identifier: resolved.identifier,
                    device: device,
                    onNewFrame: { [weak self] in
                        self?.scheduleLiveFrameNotification()
                    }
                ) {
                    syphonClients[slot] = client
                }
            }

            if let client = syphonClients[slot],
               let liveTex = client.currentTexture() {
                let rev = client.frameRevision
                if cachedLiveFrameRevisions[slot] != rev || forceFallbackIfDisconnected {
                    cachedLiveFrameRevisions[slot] = rev
                    blitLiveTexture(liveTex, flipY: true, slot: slot, into: atlasTexture)
                    return true
                }
                return false
            } else if forceFallbackIfDisconnected || cachedQuadrantTints[slot] == nil {
                uploadPatternTile(for: projector, slot: slot, into: atlasTexture)
                return true
            }
            return false

        case .ndi:
            guard let resolved = LiveVideoSourceManager.shared.resolveNDIDescriptor(
                id: projector.liveSourceID,
                name: projector.liveSourceName
            ) else {
                if let existing = ndiReceivers.removeValue(forKey: slot) {
                    existing.stop()
                }
                if forceFallbackIfDisconnected || cachedQuadrantTints[slot] == nil {
                    uploadPatternTile(for: projector, slot: slot, into: atlasTexture)
                    return true
                }
                return false
            }

            if let existing = ndiReceivers[slot],
               existing.sourceIdentifier != resolved.identifier {
                existing.stop()
                ndiReceivers.removeValue(forKey: slot)
                cachedLiveFrameRevisions.removeValue(forKey: slot)
            }

            if ndiReceivers[slot] == nil {
                if let receiver = SSKPVideoNDIReceiver(
                    source: resolved,
                    device: device,
                    onNewFrame: { [weak self] in
                        self?.scheduleLiveFrameNotification()
                    }
                ) {
                    ndiReceivers[slot] = receiver
                }
            }

            if let receiver = ndiReceivers[slot],
               let liveTex = receiver.currentTexture() {
                let rev = receiver.frameRevision
                if cachedLiveFrameRevisions[slot] != rev || forceFallbackIfDisconnected {
                    cachedLiveFrameRevisions[slot] = rev
                    blitLiveTexture(liveTex, flipY: false, slot: slot, into: atlasTexture)
                    return true
                }
                return false
            } else if forceFallbackIfDisconnected || cachedQuadrantTints[slot] == nil {
                uploadPatternTile(for: projector, slot: slot, into: atlasTexture)
                return true
            }
            return false

        default:
            return false
        }
    }

    private func blitLiveTexture(
        _ sourceTexture: MTLTexture,
        flipY: Bool,
        slot: Int,
        into atlasTexture: MTLTexture
    ) {
        guard let commandQueue,
              let blitTilePipeline,
              let cmdBuf = commandQueue.makeCommandBuffer()
        else { return }

        let w = Self.colorTileWidth
        let h = Self.colorTileHeight
        let col = slot % Self.atlasGridCols
        let row = slot / Self.atlasGridCols

        let rpDesc = MTLRenderPassDescriptor()
        rpDesc.colorAttachments[0].texture = atlasTexture
        rpDesc.colorAttachments[0].loadAction = .load
        rpDesc.colorAttachments[0].storeAction = .store

        if let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpDesc) {
            encoder.setRenderPipelineState(blitTilePipeline)
            encoder.setViewport(MTLViewport(
                originX: Double(col * w),
                originY: Double(row * h),
                width: Double(w),
                height: Double(h),
                znear: 0.0,
                zfar: 1.0
            ))
            encoder.setScissorRect(MTLScissorRect(
                x: col * w,
                y: row * h,
                width: w,
                height: h
            ))
            var flipFlag: UInt32 = flipY ? 1 : 0
            encoder.setVertexBytes(&flipFlag, length: MemoryLayout<UInt32>.stride, index: 0)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Update the 4-quadrant indirect reverberation tints from the freshly blitted tile
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: h * bytesPerRow)
        let region = MTLRegionMake2D(col * w, row * h, w, h)
        pixels.withUnsafeMutableBytes { rawBuf in
            guard let baseAddress = rawBuf.baseAddress else { return }
            atlasTexture.getBytes(baseAddress, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        }
        cachedQuadrantTints[slot] = Self.computeQuadrantBounceTints(pixels: pixels, width: w, height: h)
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

        let col = slot % Self.atlasGridCols
        let row = slot / Self.atlasGridCols
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
        if projector.spec.kind == .profileSpot {
            drawProfileSpotBeam(for: projector, in: ctx, width: w, height: h)
            return
        }
        if projector.spec.kind == .washPanel {
            drawWashPanelBeam(for: projector, in: ctx, width: w, height: h)
            return
        }

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

        case .testGrid, .syphon, .ndi:
            drawCalibrationGrid(for: projector, in: ctx, width: w, height: h)
        }
    }

    // MARK: - Stage Light Optical Beam Shaping

    private func drawProfileSpotBeam(for projector: VideoProjector, in ctx: CGContext, width w: CGFloat, height h: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        // 1. Dark aperture surround
        ctx.setFillColor(CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
        ctx.fill(rect)

        let cx = w * 0.5
        let cy = h * 0.5
        let radius = min(w, h) * 0.48

        // 2. Shutters / couteaux bounding box
        let topCut = CGFloat(projector.shutterTop) * h
        let bottomCut = CGFloat(projector.shutterBottom) * h
        let leftCut = CGFloat(projector.shutterLeft) * w
        let rightCut = CGFloat(projector.shutterRight) * w

        let shutterRect = CGRect(
            x: leftCut,
            y: topCut,
            width: max(0, w - leftCut - rightCut),
            height: max(0, h - topCut - bottomCut)
        )
        guard shutterRect.width > 1.0 && shutterRect.height > 1.0 else { return }

        ctx.saveGState()
        // Clip to the shutters box
        ctx.clip(to: shutterRect)

        // 3. Draw circular beam with radial edge softness
        let softness = CGFloat(simd_clamp(projector.edgeSoftness, 0.01, 1.0))
        let innerRadius = max(0.0, radius * (1.0 - softness * 0.65))

        let color = projector.lightColor
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let comp1: [CGFloat] = [CGFloat(color.x), CGFloat(color.y), CGFloat(color.z), 1.0]
        let comp2: [CGFloat] = [CGFloat(color.x) * 0.85, CGFloat(color.y) * 0.85, CGFloat(color.z) * 0.85, 0.95]
        let comp3: [CGFloat] = [0.0, 0.0, 0.0, 0.0]

        let locations: [CGFloat] = [0.0, 0.70, 1.0]
        let colors = [
            CGColor(colorSpace: colorSpace, components: comp1)!,
            CGColor(colorSpace: colorSpace, components: comp2)!,
            CGColor(colorSpace: colorSpace, components: comp3)!
        ] as CFArray

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
            ctx.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: cx, y: cy),
                startRadius: innerRadius,
                endCenter: CGPoint(x: cx, y: cy),
                endRadius: radius,
                options: [.drawsBeforeStartLocation]
            )
        }

        ctx.restoreGState()
    }

    private func drawWashPanelBeam(for projector: VideoProjector, in ctx: CGContext, width w: CGFloat, height h: CGFloat) {
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        // 1. Dark surround
        ctx.setFillColor(CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 1.0))
        ctx.fill(rect)

        let cx = w * 0.5
        let cy = h * 0.5

        // Barn doors cut
        let topCut = CGFloat(projector.shutterTop) * h
        let bottomCut = CGFloat(projector.shutterBottom) * h
        let leftCut = CGFloat(projector.shutterLeft) * w
        let rightCut = CGFloat(projector.shutterRight) * w

        let barnDoorRect = CGRect(
            x: leftCut,
            y: topCut,
            width: max(0, w - leftCut - rightCut),
            height: max(0, h - topCut - bottomCut)
        )
        guard barnDoorRect.width > 1.0 && barnDoorRect.height > 1.0 else { return }

        ctx.saveGState()
        ctx.clip(to: barnDoorRect)

        let color = projector.lightColor
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let maxRadius = max(w, h) * 0.58

        // Wide soft cosine-like falloff for wash flood
        let comp1: [CGFloat] = [CGFloat(color.x), CGFloat(color.y), CGFloat(color.z), 1.0]
        let comp2: [CGFloat] = [CGFloat(color.x) * 0.65, CGFloat(color.y) * 0.65, CGFloat(color.z) * 0.65, 0.70]
        let comp3: [CGFloat] = [0.0, 0.0, 0.0, 0.0]

        let locations: [CGFloat] = [0.0, 0.55, 1.0]
        let colors = [
            CGColor(colorSpace: colorSpace, components: comp1)!,
            CGColor(colorSpace: colorSpace, components: comp2)!,
            CGColor(colorSpace: colorSpace, components: comp3)!
        ] as CFArray

        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations) {
            ctx.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: cx, y: cy),
                startRadius: 0.0,
                endCenter: CGPoint(x: cx, y: cy),
                endRadius: maxRadius,
                options: [.drawsBeforeStartLocation]
            )
        }

        ctx.restoreGState()
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
    texture2d<float, access::sample> sskp_projDepth;
    texture2d<float, access::sample> sskp_projColor;
    texture2d<float, access::sample> sskp_projData;

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

        for (int sskp_i = 0; sskp_i < 12; ++sskp_i) {
            if (sskp_i >= sskp_projCount) { break; }
            uint sskp_row = uint(sskp_i);
            float4 sskp_pi = sskp_projData.read(uint2(4u, sskp_row), 0);
            float sskp_intensity = sskp_pi.w;
            if (sskp_intensity <= 0.0001) { continue; }
            float4x4 sskp_vp = float4x4(
                sskp_projData.read(uint2(0u, sskp_row), 0),
                sskp_projData.read(uint2(1u, sskp_row), 0),
                sskp_projData.read(uint2(2u, sskp_row), 0),
                sskp_projData.read(uint2(3u, sskp_row), 0)
            );

            // 1. Indirect Light Reverberation (QuestVR Seine Musicale 4-Quadrant Bounce)
            float4x4 sskp_bPosMat = float4x4(
                sskp_projData.read(uint2(6u,  sskp_row), 0),
                sskp_projData.read(uint2(7u,  sskp_row), 0),
                sskp_projData.read(uint2(8u,  sskp_row), 0),
                sskp_projData.read(uint2(9u,  sskp_row), 0)
            );
            float4x4 sskp_bNormMat = float4x4(
                sskp_projData.read(uint2(10u, sskp_row), 0),
                sskp_projData.read(uint2(11u, sskp_row), 0),
                sskp_projData.read(uint2(12u, sskp_row), 0),
                sskp_projData.read(uint2(13u, sskp_row), 0)
            );
            float4x4 sskp_bColMat = float4x4(
                sskp_projData.read(uint2(14u, sskp_row), 0),
                sskp_projData.read(uint2(15u, sskp_row), 0),
                sskp_projData.read(uint2(16u, sskp_row), 0),
                sskp_projData.read(uint2(17u, sskp_row), 0)
            );
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

            float2 sskp_tileOrigin = float2(float(sskp_i % 4), float(sskp_i / 4)) * 0.25;
            float2 sskp_uvClamped = clamp(float2(sskp_u, sskp_v), float2(0.002), float2(0.998));
            float2 sskp_atlasUV = sskp_tileOrigin + sskp_uvClamped * 0.25;

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

            float4 sskp_photo = sskp_projData.read(uint2(5u, sskp_row), 0);
            float sskp_projGain = sskp_intensity * 1.45;

            // Photometric mode: sskp_photo.w holds reference lux (e.g. 250 lx), sskp_photo.x holds effective lumens,
            // sskp_photo.y holds throwRatio, sskp_photo.z holds aspectRatio.
            if (sskp_photo.w > 0.5) {
                float sskp_dEye = max(sskp_w, 0.15);
                float sskp_tr = max(sskp_photo.y, 0.05);
                float sskp_ar = max(sskp_photo.z, 0.5);
                // Physical cross-section area: A = (dEye / TR) * (dEye / (TR * AR)) = dEye^2 / (TR^2 * AR)
                float sskp_beamArea = (sskp_dEye * sskp_dEye) / (sskp_tr * sskp_tr * sskp_ar);
                float sskp_lux = sskp_photo.x / max(sskp_beamArea, 0.02);

                // Optical lens falloff / vignetting (ANSI uniformity ~85% center to corner)
                float2 sskp_cr = float2(sskp_u - 0.5, sskp_v - 0.5) * 2.0;
                float sskp_r2 = dot(sskp_cr, sskp_cr);
                float sskp_vignette = clamp(1.0 - 0.16 * min(sskp_r2 * 0.5, 1.0), 0.70, 1.0);

                // Normalise relative to reference lux (refLux maps to ~1.0 SDR white emission)
                float sskp_refLux = max(sskp_photo.w, 10.0);
                sskp_projGain = (sskp_lux / sskp_refLux) * sskp_vignette * 1.35;
            }

            // 3. Analytical 4-blade shutters / barn-doors & optical beam profile (RGB/RGBW Stage Lights & Video Projectors)
            float4 sskp_beamColor = sskp_projData.read(uint2(18u, sskp_row), 0);
            float4 sskp_shutters  = sskp_projData.read(uint2(19u, sskp_row), 0);
            float4 sskp_shape     = sskp_projData.read(uint2(20u, sskp_row), 0);
            float sskp_kind       = sskp_shape.x;
            float sskp_softness   = clamp(sskp_shape.y, 0.005, 1.0);

            float sskp_sFeather = max(0.004, sskp_softness * 0.075);
            float sskp_shMask = smoothstep(sskp_shutters.x, sskp_shutters.x + sskp_sFeather, sskp_u)
                              * smoothstep(sskp_shutters.y, sskp_shutters.y + sskp_sFeather, 1.0 - sskp_u)
                              * smoothstep(sskp_shutters.z, sskp_shutters.z + sskp_sFeather, sskp_v)
                              * smoothstep(sskp_shutters.w, sskp_shutters.w + sskp_sFeather, 1.0 - sskp_v);
            if (sskp_shMask <= 0.001) { continue; }

            float3 sskp_img;
            if (sskp_kind >= 1.5) {
                // Wash / PAR RGBW: smooth cosine flood profile evaluated analytically at native pixel resolution
                float2 sskp_centered = float2(sskp_u - 0.5, sskp_v - 0.5) * 2.0;
                float sskp_r = length(sskp_centered);
                float sskp_outer = 1.04 + 0.14 * sskp_softness;
                float sskp_falloff = 1.0 - smoothstep(0.14 * (1.0 - sskp_softness), sskp_outer, sskp_r);
                float sskp_beamProfile = pow(sskp_falloff, mix(1.18, 0.72, sskp_softness));
                sskp_img = sskp_beamColor.rgb * (sskp_beamProfile * sskp_shMask);
            } else if (sskp_kind >= 0.5) {
                // Profile Spot (Découpe): circular optical gate with adjustable knife-edge / frost focus
                float2 sskp_centered = float2(sskp_u - 0.5, sskp_v - 0.5) * 2.0;
                float sskp_r = length(sskp_centered);
                float sskp_inner = max(0.0, 0.96 * (1.0 - sskp_softness * 0.68));
                float sskp_edge = 1.0 - smoothstep(sskp_inner, 0.98, sskp_r);
                float sskp_flat = mix(1.0, 0.88, min(sskp_r * sskp_r, 1.0));
                sskp_img = sskp_beamColor.rgb * (sskp_edge * sskp_flat * sskp_shMask);
            } else {
                // Video Projector: sample 4x4 video/pattern atlas tile + apply shutters and optical tint
                float3 sskp_texRGB = sskp_projColor.sample(sskp_colorSampler, sskp_atlasUV).rgb;
                sskp_img = sskp_texRGB * sskp_beamColor.rgb * sskp_shMask;
            }

            float3 sskp_albedo = mix(float3(1.0), _surface.diffuse.rgb, 0.32);
            sskp_totalProj += sskp_img * sskp_albedo * (sskp_projGain * sskp_vis * sskp_inc);
        }
        // Soft Reinhard compression on accumulated indirect bounce (as in QuestVR rebond_video.gdshaderinc)
        sskp_totalRebond = sskp_totalRebond / (float3(1.0) + sskp_totalRebond * 0.45);
        float3 sskp_rebondAlbedo = mix(float3(0.32), _surface.diffuse.rgb, 0.68);
        float3 sskp_combined = sskp_totalProj + sskp_rebondAlbedo * sskp_totalRebond;

        // Chromatic-preserving filmic highlight roll-off for multi-projector (RGB/RGBW lights + video) additive mixing:
        // Preserves linear additive color sums up to 1.15, then smoothly rolls off intense overlapping beams
        // while gently blooming hot cores toward luminous white without hue skewing.
        float sskp_peak = max(sskp_combined.r, max(sskp_combined.g, sskp_combined.b));
        if (sskp_peak > 1.15) {
            float sskp_compressed = 1.15 + (sskp_peak - 1.15) / (1.0 + 0.55 * (sskp_peak - 1.15));
            float3 sskp_scaled = sskp_combined * (sskp_compressed / sskp_peak);
            float sskp_luma = dot(sskp_scaled, float3(0.2126, 0.7152, 0.0722));
            float sskp_hotWhite = clamp((sskp_peak - 1.35) * 0.22, 0.0, 0.35);
            sskp_combined = mix(sskp_scaled, float3(sskp_luma), sskp_hotWhite);
        }
        _surface.emission.rgb = sskp_combined;
    }
    """
}
