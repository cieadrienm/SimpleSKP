import Foundation
import Metal
import SceneKit
import simd
import SimpleSKPCore

/// High-performance Metal renderer for 3D Gaussian Splats and 3D Point Clouds, integrating and
/// optimizing `MetalSplatter`'s EWA splatting + Spherical Harmonics (SH0–SH3) math with:
/// - Single-draw-call hardware instancing (`triangleStrip`, 4 vertices × N instances)
/// - 4 bytes/splat sorted index buffer (6× smaller than `MetalSplatter`'s 24 bytes/splat quad index buffer)
/// - Sub-millisecond 16-bit (65,536-bucket) parallel Counting/Radix Sort with `sqrt` depth distribution
/// - Runtime shader compilation via `makeLibrary(source:)` (works in `swift build`, `--self-test`, and `--snapshot`)
final class MetalSplatRenderer: NSObject, SCNNodeRendererDelegate, @unchecked Sendable {

    private struct SplatUniforms {
        var modelViewMatrix: simd_float4x4
        var projectionMatrix: simd_float4x4
        var shDirMatrix: simd_float3x3
        var cameraPosModel: SIMD4<Float>      // xyz = camera position in Z-up model space
        var screenSize: SIMD2<Float>          // width, height in pixels
        var splatCount: UInt32
        var shDegree: UInt32
        var shFloatsPerSplat: UInt32
        var renderMode: UInt32                // 0 = 3DGS, 1 = Point Cloud
        var shadingMode: UInt32               // 0 = Textured/Color, 1 = Clay, 2 = X-Ray
        var useSortedIndices: UInt32          // 1 = read sortedIndices[instanceID], 0 = use instanceID
        var pointRadiusMeters: Float
        var hdrGain: Float
        var splatScale: Float
        var pad0: Float = 0
    }

    private struct PipelineKey: Hashable {
        var colorFormat: UInt
        var depthFormat: UInt
        var sampleCount: Int
        var blendTranslucent: Bool
        var writeDepth: Bool
    }

    private let cloud: SKPModel.SplatCloud
    private let boundsMin: SIMD3<Float>
    private let boundsMax: SIMD3<Float>
    private let boundsCorners: [SIMD3<Float>]

    // Current viewport settings updated from `ViewportScene`
    var shadingStyle: ShadingStyle = .textured
    var pointScaleFactor: Float = 1.0
    var isHiddenLayer: Bool = false

    // Metal resources (guarded by `renderLock` for thread safety across SCNView & Syphon SCNRenderer)
    private let renderLock = NSLock()
    private var initializedDeviceID: UInt64 = 0
    private var library: MTLLibrary?
    private var splatBuffer: MTLBuffer?
    private var shBuffer: MTLBuffer?
    private var indexBuffers: [MTLBuffer] = []
    private var activeIndexBufferSlot: Int = 0
    private var pipelineCache: [PipelineKey: MTLRenderPipelineState] = [:]
    private var depthStates: [Bool: MTLDepthStencilState] = [:]

    // Sorting scratch buffers (reused across sorts to avoid allocations)
    private var hasValidSort: Bool = false
    private var lastSortedCamPos = SIMD3<Float>(repeating: .nan)
    private var lastSortedCamFwd = SIMD3<Float>(repeating: .nan)
    private var bucketScratch: [UInt16] = []
    private var threadHistograms: [Int32] = []

    init(cloud: SKPModel.SplatCloud, boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>) {
        self.cloud = cloud
        self.boundsMin = boundsMin
        self.boundsMax = boundsMax
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(8)
        for i in 0..<8 {
            corners.append(SIMD3<Float>(
                (i & 1) == 0 ? boundsMin.x : boundsMax.x,
                (i & 2) == 0 ? boundsMin.y : boundsMax.y,
                (i & 4) == 0 ? boundsMin.z : boundsMax.z
            ))
        }
        self.boundsCorners = corners
        super.init()
    }

    // MARK: - SCNNodeRendererDelegate

    func renderNode(
        _ node: SCNNode,
        renderer: SCNRenderer,
        arguments: [String: Any]
    ) {
        guard !isHiddenLayer, cloud.count > 0 else { return }
        let passDesc = renderer.currentRenderPassDescriptor
        guard let device = renderer.device,
              let encoder = renderer.currentRenderCommandEncoder,
              let colorTex = passDesc.colorAttachments[0].texture else {
            return
        }

        renderLock.lock()
        defer { renderLock.unlock() }

        guard ensureResources(device: device),
              let splatBuffer,
              let shBuffer,
              !indexBuffers.isEmpty else {
            return
        }

        // Extract transforms from SceneKit's `arguments` (which already include `modelRoot`'s Z-up -> Y-up transform)
        let mvMatrix: simd_float4x4
        if let v = arguments["kModelViewTransform"] as? NSValue {
            mvMatrix = simd_float4x4( v.scnMatrix4Value )
        } else {
            mvMatrix = matrix_identity_float4x4
        }

        let projMatrix: simd_float4x4
        if let v = arguments["kProjectionTransform"] as? NSValue {
            projMatrix = simd_float4x4( v.scnMatrix4Value )
        } else {
            projMatrix = matrix_identity_float4x4
        }

        // Compute camera position and forward direction in Z-up model space from `mvMatrix^-1`
        let invMV = mvMatrix.inverse
        let camPosModel = SIMD3<Float>(invMV.columns.3.x, invMV.columns.3.y, invMV.columns.3.z)
        // In SceneKit eye space, the camera looks down -Z
        let camFwdModelRaw = -SIMD3<Float>(invMV.columns.2.x, invMV.columns.2.y, invMV.columns.2.z)
        let fwdLen = simd_length(camFwdModelRaw)
        let camFwdModel = fwdLen > 1e-6 ? (camFwdModelRaw / fwdLen) : SIMD3<Float>(0, 1, 0)

        // Determine render mode and shading mode
        // - For `.gaussianSplats`: Textured/Clay/X-Ray use 3DGS EWA covariance splatting; Wireframe shows crisp Gaussian centers as points.
        // - For `.pointCloud`: all styles use crisp anti-aliased surfel points.
        let usePointMode = (cloud.kind == .pointCloud) || (shadingStyle == .wireframe)
        let renderMode: UInt32 = usePointMode ? 1 : 0
        let shadingMode: UInt32 = {
            switch shadingStyle {
            case .clay: return 1
            case .xray: return 2
            case .textured, .wireframe: return 0
            }
        }()

        let needsBackToFrontSort = (renderMode == 0) || (shadingMode == 2)
        if needsBackToFrontSort {
            sortIfNeeded(cameraPos: camPosModel, cameraForward: camFwdModel)
        }

        let colorFormat = colorTex.pixelFormat
        let sampleCount = max(1, colorTex.sampleCount)
        let depthFormat = passDesc.depthAttachment.texture?.pixelFormat ?? renderer.depthPixelFormat

        let blendTranslucent = needsBackToFrontSort
        let writeDepth = !needsBackToFrontSort
        let pipeKey = PipelineKey(
            colorFormat: colorFormat.rawValue,
            depthFormat: depthFormat.rawValue,
            sampleCount: sampleCount,
            blendTranslucent: blendTranslucent,
            writeDepth: writeDepth
        )
        guard let pso = pipelineState(for: pipeKey, device: device, colorFormat: colorFormat, depthFormat: depthFormat),
              let dss = depthStates[writeDepth] else {
            return
        }

        let shFloatsPerSplat: UInt32 = {
            switch cloud.shDegree {
            case 1: return 9
            case 2: return 24
            case 3: return 45
            default: return 0
            }
        }()

        // When SceneKit's HDR camera is active (`colorFormat == .rgba16Float`), its tone-mapper applies `exposureOffset = -0.62`.
        // Applying a 1.48 linear gain restores natural sRGB brightness while responding to the user's Exposure slider.
        let hdrGain: Float = (colorFormat == .rgba16Float) ? 1.48 : 1.0

        var uniforms = SplatUniforms(
            modelViewMatrix: mvMatrix,
            projectionMatrix: projMatrix,
            shDirMatrix: simd_float3x3(cloud.shDirCol0, cloud.shDirCol1, cloud.shDirCol2),
            cameraPosModel: SIMD4<Float>(camPosModel.x, camPosModel.y, camPosModel.z, 1.0),
            screenSize: SIMD2<Float>(Float(max(1, colorTex.width)), Float(max(1, colorTex.height))),
            splatCount: UInt32(cloud.count),
            shDegree: UInt32(cloud.shDegree),
            shFloatsPerSplat: shFloatsPerSplat,
            renderMode: renderMode,
            shadingMode: shadingMode,
            useSortedIndices: needsBackToFrontSort ? 1 : 0,
            pointRadiusMeters: cloud.defaultPointRadius * pointScaleFactor,
            hdrGain: hdrGain,
            splatScale: pointScaleFactor
        )

        let idxBuffer = indexBuffers[activeIndexBufferSlot]
        encoder.setRenderPipelineState(pso)
        encoder.setDepthStencilState(dss)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(idxBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(splatBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SplatUniforms>.stride, index: 2)
        encoder.setVertexBuffer(shBuffer, offset: 0, index: 3)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SplatUniforms>.stride, index: 2)

        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4,
            instanceCount: cloud.count
        )
    }

    // MARK: - 16-Bit Parallel Counting/Radix Sorter (Back-to-Front)

    private func sortIfNeeded(cameraPos: SIMD3<Float>, cameraForward: SIMD3<Float>) {
        guard cameraPos.x.isFinite && cameraForward.x.isFinite else { return }

        if hasValidSort {
            let modelDiag = max(0.1, simd_length(boundsMax - boundsMin))
            let posDelta = simd_distance(cameraPos, lastSortedCamPos)
            let dirDot = simd_clamp(simd_dot(cameraForward, lastSortedCamFwd), -1.0, 1.0)
            // Skip re-sorting if camera moved less than 0.15% of model size and rotated less than ~0.25 degrees
            if posDelta < modelDiag * 0.0015 && dirDot > 0.99999 {
                return
            }
        }

        let count = cloud.count
        guard count > 0, !indexBuffers.isEmpty else { return }

        // Advance triple-buffered index slot
        activeIndexBufferSlot = (activeIndexBufferSlot + 1) % indexBuffers.count
        let targetBuffer = indexBuffers[activeIndexBufferSlot]
        let outIndices = targetBuffer.contents().assumingMemoryBound(to: UInt32.self)

        if count == 1 {
            outIndices[0] = 0
            hasValidSort = true
            lastSortedCamPos = cameraPos
            lastSortedCamFwd = cameraForward
            return
        }

        // Compute exact min/max depth of the bounding box along `cameraForward`
        var minDepth: Float = .infinity
        var maxDepth: Float = -.infinity
        for corner in boundsCorners {
            let d = simd_dot(corner - cameraPos, cameraForward)
            if d < minDepth { minDepth = d }
            if d > maxDepth { maxDepth = d }
        }
        let depthSpan = max(1e-5, maxDepth - minDepth)
        let invDepthSpan = 1.0 / depthSpan

        let numBuckets = 65_536
        let numThreads = max(1, min(8, count / 16_384))
        let perThread = (count + numThreads - 1) / numThreads

        if bucketScratch.count != count {
            bucketScratch = [UInt16](repeating: 0, count: count)
        }
        if threadHistograms.count != numThreads * numBuckets {
            threadHistograms = [Int32](repeating: 0, count: numThreads * numBuckets)
        } else {
            threadHistograms.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress?.initialize(repeating: 0, count: buf.count)
            }
        }

        cloud.splats.withUnsafeBufferPointer { splatBuf in
            bucketScratch.withUnsafeMutableBufferPointer { bScratch in
                threadHistograms.withUnsafeMutableBufferPointer { histBuf in
                    let sPtr = splatBuf.baseAddress!
                    let bPtr = bScratch.baseAddress!
                    let hPtr = histBuf.baseAddress!

                    // Pass 1: Compute 16-bit depth buckets (far = 0, near = 65535) and per-thread histograms
                    if numThreads == 1 {
                        for i in 0..<count {
                            let s = sPtr[i]
                            let dx = s.px - cameraPos.x
                            let dy = s.py - cameraPos.y
                            let dz = s.pz - cameraPos.z
                            let d = dx * cameraForward.x + dy * cameraForward.y + dz * cameraForward.z
                            let norm = simd_clamp((d - minDepth) * invDepthSpan, 0.0, 1.0)
                            // sqrt mapping gives higher bucket resolution near the camera
                            let farToNear = 1.0 - sqrt(norm)
                            let bucket = UInt16(farToNear * 65535.0)
                            bPtr[i] = bucket
                            hPtr[Int(bucket)] &+= 1
                        }
                    } else {
                        DispatchQueue.concurrentPerform(iterations: numThreads) { t in
                            let startIdx = t * perThread
                            let endIdx = min(count, startIdx + perThread)
                            guard startIdx < endIdx else { return }
                            let localHist = hPtr.advanced(by: t * numBuckets)
                            for i in startIdx..<endIdx {
                                let s = sPtr[i]
                                let dx = s.px - cameraPos.x
                                let dy = s.py - cameraPos.y
                                let dz = s.pz - cameraPos.z
                                let d = dx * cameraForward.x + dy * cameraForward.y + dz * cameraForward.z
                                let norm = simd_clamp((d - minDepth) * invDepthSpan, 0.0, 1.0)
                                let farToNear = 1.0 - sqrt(norm)
                                let bucket = UInt16(farToNear * 65535.0)
                                bPtr[i] = bucket
                                localHist[Int(bucket)] &+= 1
                            }
                        }
                    }

                    // Pass 2: Exclusive prefix sum across buckets and threads
                    var runningOffset: Int32 = 0
                    for b in 0..<numBuckets {
                        for t in 0..<numThreads {
                            let idx = t * numBuckets + b
                            let c = hPtr[idx]
                            hPtr[idx] = runningOffset
                            runningOffset &+= c
                        }
                    }

                    // Pass 3: Scatter splat indices into `outIndices` in back-to-front order
                    if numThreads == 1 {
                        for i in 0..<count {
                            let b = Int(bPtr[i])
                            let dst = Int(hPtr[b])
                            hPtr[b] &+= 1
                            outIndices[dst] = UInt32(i)
                        }
                    } else {
                        DispatchQueue.concurrentPerform(iterations: numThreads) { t in
                            let startIdx = t * perThread
                            let endIdx = min(count, startIdx + perThread)
                            guard startIdx < endIdx else { return }
                            let localOffsets = hPtr.advanced(by: t * numBuckets)
                            for i in startIdx..<endIdx {
                                let b = Int(bPtr[i])
                                let dst = Int(localOffsets[b])
                                localOffsets[b] &+= 1
                                outIndices[dst] = UInt32(i)
                            }
                        }
                    }
                }
            }
        }

        hasValidSort = true
        lastSortedCamPos = cameraPos
        lastSortedCamFwd = cameraForward
    }

    // MARK: - Metal Resource & Pipeline Setup

    private func ensureResources(device: MTLDevice) -> Bool {
        if initializedDeviceID == device.registryID,
           library != nil,
           splatBuffer != nil,
           !indexBuffers.isEmpty {
            return true
        }

        pipelineCache.removeAll()
        depthStates.removeAll()
        indexBuffers.removeAll()
        hasValidSort = false

        let opts = MTLCompileOptions()
        opts.mathMode = .fast
        guard let lib = try? device.makeLibrary(source: Self.metalShaderSource, options: opts) else {
            return false
        }
        self.library = lib

        let splatByteLength = max(32, cloud.splats.count * MemoryLayout<SKPModel.PackedSplat>.stride)
        let sBuf = cloud.splats.withUnsafeBytes { raw in
            device.makeBuffer(bytes: raw.baseAddress!, length: splatByteLength, options: .storageModeShared)
        }
        guard let sBuf else { return false }
        self.splatBuffer = sBuf

        if !cloud.shCoefficients.isEmpty {
            let shBytes = cloud.shCoefficients.count * MemoryLayout<Float16>.stride
            self.shBuffer = cloud.shCoefficients.withUnsafeBytes { raw in
                device.makeBuffer(bytes: raw.baseAddress!, length: shBytes, options: .storageModeShared)
            }
        } else {
            var dummy: Float16 = 0
            self.shBuffer = device.makeBuffer(bytes: &dummy, length: MemoryLayout<Float16>.stride, options: .storageModeShared)
        }

        let indexByteLength = max(4, cloud.count * MemoryLayout<UInt32>.stride)
        for _ in 0..<3 {
            guard let ib = device.makeBuffer(length: indexByteLength, options: .storageModeShared) else {
                return false
            }
            indexBuffers.append(ib)
        }

        // Depth states: one with depth write OFF (for translucent 3DGS / X-Ray), one with depth write ON (for opaque Point Clouds)
        for writeDepth in [false, true] {
            let dDesc = MTLDepthStencilDescriptor()
            dDesc.depthCompareFunction = .lessEqual
            dDesc.isDepthWriteEnabled = writeDepth
            if let state = device.makeDepthStencilState(descriptor: dDesc) {
                depthStates[writeDepth] = state
            }
        }

        initializedDeviceID = device.registryID
        return true
    }

    private func pipelineState(
        for key: PipelineKey,
        device: MTLDevice,
        colorFormat: MTLPixelFormat,
        depthFormat: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        if let cached = pipelineCache[key] {
            return cached
        }
        guard let library,
              let vFunc = library.makeFunction(name: "splatVertexMain"),
              let fFunc = library.makeFunction(name: "splatFragmentMain") else {
            return nil
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vFunc
        desc.fragmentFunction = fFunc
        desc.rasterSampleCount = key.sampleCount
        desc.depthAttachmentPixelFormat = depthFormat

        let ca = desc.colorAttachments[0]!
        ca.pixelFormat = colorFormat
        if key.blendTranslucent {
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        } else {
            ca.isBlendingEnabled = false
        }

        guard let pso = try? device.makeRenderPipelineState(descriptor: desc) else {
            return nil
        }
        pipelineCache[key] = pso
        return pso
    }

    // MARK: - Embedded Metal Shader (`MetalSplatter` 3DGS EWA + SH0..SH3 + Point Cloud Surfels)

    private static let metalShaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    constant float kBoundsRadius = 3.0f;
    constant float kBoundsRadiusSquared = 9.0f;
    constant half kMinAlpha = 1.0h / 255.0h;

    constant half SH_C1 = 0.4886025119029199h;
    constant half SH_C2_0 = 1.0925484305920792h;
    constant half SH_C2_1 = -1.0925484305920792h;
    constant half SH_C2_2 = 0.31539156525252005h;
    constant half SH_C2_3 = -1.0925484305920792h;
    constant half SH_C2_4 = 0.5462742152960396h;

    constant half SH_C3_0 = -0.5900435899266435h;
    constant half SH_C3_1 = 2.890611442640554h;
    constant half SH_C3_2 = -0.4570457994644658h;
    constant half SH_C3_3 = 0.3731763325901154h;
    constant half SH_C3_4 = -0.4570457994644658h;
    constant half SH_C3_5 = 1.445305721320277h;
    constant half SH_C3_6 = -0.5900435899266435h;

    struct Splat {
        packed_float3 position;
        packed_half4 color;
        packed_half3 covA;
        packed_half3 covB;
    };

    struct SplatUniforms {
        float4x4 modelViewMatrix;
        float4x4 projectionMatrix;
        float3x3 shDirMatrix;
        float4 cameraPosModel;
        float2 screenSize;
        uint splatCount;
        uint shDegree;
        uint shFloatsPerSplat;
        uint renderMode;         // 0 = 3DGS, 1 = Point Cloud
        uint shadingMode;        // 0 = Textured/Color, 1 = Clay, 2 = X-Ray
        uint useSortedIndices;
        float pointRadiusMeters;
        float hdrGain;
        float splatScale;
        float pad0;
    };

    struct FragmentIn {
        float4 position [[position]];
        half2 relativePosition;
        half4 color;
        uint renderMode [[flat]];
        uint shadingMode [[flat]];
    };

    inline float3 calcCovariance2D(
        float3 viewPos,
        packed_half3 cov3Da,
        packed_half3 cov3Db,
        float4x4 viewMatrix,
        float4x4 projectionMatrix,
        float2 screenSize
    ) {
        bool isOrtho = (abs(projectionMatrix[3][3]) > 0.5f);
        float2 focal = float2(projectionMatrix[0][0] * screenSize.x, projectionMatrix[1][1] * screenSize.y) * 0.5f;

        float3x3 J;
        if (isOrtho) {
            J = float3x3(
                focal.x, 0.0f, 0.0f,
                0.0f, focal.y, 0.0f,
                0.0f, 0.0f, 0.0f
            );
        } else {
            float invViewPosZ = 1.0f / viewPos.z;
            float invViewPosZSquared = invViewPosZ * invViewPosZ;
            float tanHalfFovX = 1.0f / projectionMatrix[0][0];
            float tanHalfFovY = 1.0f / projectionMatrix[1][1];
            float limX = 1.3f * tanHalfFovX;
            float limY = 1.3f * tanHalfFovY;
            viewPos.x = clamp(viewPos.x * invViewPosZ, -limX, limX) * viewPos.z;
            viewPos.y = clamp(viewPos.y * invViewPosZ, -limY, limY) * viewPos.z;

            J = float3x3(
                focal.x * invViewPosZ, 0.0f, 0.0f,
                0.0f, focal.y * invViewPosZ, 0.0f,
                -(focal.x * viewPos.x) * invViewPosZSquared, -(focal.y * viewPos.y) * invViewPosZSquared, 0.0f
            );
        }

        float3x3 W = float3x3(viewMatrix[0].xyz, viewMatrix[1].xyz, viewMatrix[2].xyz);
        float3x3 T = J * W;
        float3x3 Vrk = float3x3(
            cov3Da.x, cov3Da.y, cov3Da.z,
            cov3Da.y, cov3Db.x, cov3Db.y,
            cov3Da.z, cov3Db.y, cov3Db.z
        );
        float3x3 cov = T * Vrk * transpose(T);

        // Apply 0.3 px low-pass filter so sub-pixel splats remain at least 1 pixel wide
        cov[0][0] += 0.3f;
        cov[1][1] += 0.3f;
        return float3(cov[0][0], cov[0][1], cov[1][1]);
    }

    inline void decomposeCovariance(float3 cov2D, thread float2 &v1, thread float2 &v2) {
        float a = cov2D.x;
        float b = cov2D.y;
        float d = cov2D.z;
        float det = a * d - b * b;
        float trace = a + d;

        float mean = 0.5f * trace;
        float dist = max(0.1f, sqrt(max(0.0f, mean * mean - det)));

        float lambda1 = mean + dist;
        float lambda2 = max(0.0f, mean - dist);

        float2 eigenvector1;
        if (abs(b) < 1e-6f) {
            eigenvector1 = (a > d) ? float2(1.0f, 0.0f) : float2(0.0f, 1.0f);
        } else {
            float2 unnormalized = float2(b, d - lambda2);
            eigenvector1 = normalize(unnormalized);
        }
        float2 eigenvector2 = float2(eigenvector1.y, -eigenvector1.x);

        v1 = eigenvector1 * sqrt(lambda1 * 2.0f);
        v2 = eigenvector2 * sqrt(lambda2 * 2.0f);
    }

    inline half3 evaluateSHBands(half3 dir, constant half *shBase, uint degree) {
        half3 result = half3(0.0h);
        if (degree < 1) { return result; }

        half x = dir.x;
        half y = dir.y;
        half z = dir.z;

        half3 sh1 = half3(shBase[0], shBase[1], shBase[2]);
        half3 sh2 = half3(shBase[3], shBase[4], shBase[5]);
        half3 sh3 = half3(shBase[6], shBase[7], shBase[8]);
        result += SH_C1 * (-y * sh1 + z * sh2 - x * sh3);

        if (degree < 2) { return result; }

        half xx = x * x, yy = y * y, zz = z * z;
        half xy = x * y, yz = y * z, xz = x * z;

        half3 sh4 = half3(shBase[9],  shBase[10], shBase[11]);
        half3 sh5 = half3(shBase[12], shBase[13], shBase[14]);
        half3 sh6 = half3(shBase[15], shBase[16], shBase[17]);
        half3 sh7 = half3(shBase[18], shBase[19], shBase[20]);
        half3 sh8 = half3(shBase[21], shBase[22], shBase[23]);

        result += SH_C2_0 * xy * sh4 +
                  SH_C2_1 * yz * sh5 +
                  SH_C2_2 * (2.0h * zz - xx - yy) * sh6 +
                  SH_C2_3 * xz * sh7 +
                  SH_C2_4 * (xx - yy) * sh8;

        if (degree < 3) { return result; }

        half3 sh9  = half3(shBase[24], shBase[25], shBase[26]);
        half3 sh10 = half3(shBase[27], shBase[28], shBase[29]);
        half3 sh11 = half3(shBase[30], shBase[31], shBase[32]);
        half3 sh12 = half3(shBase[33], shBase[34], shBase[35]);
        half3 sh13 = half3(shBase[36], shBase[37], shBase[38]);
        half3 sh14 = half3(shBase[39], shBase[40], shBase[41]);
        half3 sh15 = half3(shBase[42], shBase[43], shBase[44]);

        result += SH_C3_0 * y * (3.0h * xx - yy) * sh9 +
                  SH_C3_1 * xy * z * sh10 +
                  SH_C3_2 * y * (4.0h * zz - xx - yy) * sh11 +
                  SH_C3_3 * z * (2.0h * zz - 3.0h * xx - 3.0h * yy) * sh12 +
                  SH_C3_4 * x * (4.0h * zz - xx - yy) * sh13 +
                  SH_C3_5 * z * (xx - yy) * sh14 +
                  SH_C3_6 * x * (xx - 3.0h * yy) * sh15;

        return result;
    }

    vertex FragmentIn splatVertexMain(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant uint32_t *sortedIndices [[buffer(0)]],
        constant Splat *splatArray [[buffer(1)]],
        constant SplatUniforms &uniforms [[buffer(2)]],
        constant half *shCoeffs [[buffer(3)]]
    ) {
        FragmentIn out;
        out.renderMode = uniforms.renderMode;
        out.shadingMode = uniforms.shadingMode;

        uint splatIdx = (uniforms.useSortedIndices != 0) ? sortedIndices[instanceID] : instanceID;
        Splat splat = splatArray[splatIdx];
        float3 modelPos = float3(splat.position);

        float4 viewPos4 = uniforms.modelViewMatrix * float4(modelPos, 1.0f);
        if (viewPos4.z >= -0.001f) {
            out.position = float4(0.0f, 0.0f, 2.0f, 1.0f);
            out.color = half4(0.0h);
            out.relativePosition = half2(0.0h);
            return out;
        }

        float4 clipCenter = uniforms.projectionMatrix * viewPos4;
        float clipOverW = abs(clipCenter.z) / max(1e-6f, abs(clipCenter.w));
        if (clipOverW > 1.001f) {
            out.position = float4(0.0f, 0.0f, 2.0f, 1.0f);
            out.color = half4(0.0h);
            out.relativePosition = half2(0.0h);
            return out;
        }

        half4 baseColor = half4(splat.color);
        if (uniforms.shDegree >= 1 && uniforms.shFloatsPerSplat > 0 && uniforms.shadingMode == 0) {
            float3 viewVecModel = modelPos - uniforms.cameraPosModel.xyz;
            float vLen = length(viewVecModel);
            if (vLen > 1e-6f) {
                float3 dirNative = uniforms.shDirMatrix * (viewVecModel / vLen);
                constant half *shBase = shCoeffs + (splatIdx * uniforms.shFloatsPerSplat);
                baseColor.rgb = max(half3(0.0h), baseColor.rgb + evaluateSHBands(half3(dirNative), shBase, uniforms.shDegree));
            }
        }

        // Apply Clay or X-Ray style tint if selected in toolbar
        if (uniforms.shadingMode == 1) {
            // Clay: warm architectural plaster modulated by splat luminance
            half luma = dot(baseColor.rgb, half3(0.299h, 0.587h, 0.114h));
            half shade = mix(0.42h, 0.96h, clamp(luma, 0.0h, 1.0h));
            baseColor.rgb = half3(0.90h, 0.87h, 0.82h) * shade;
        } else if (uniforms.shadingMode == 2) {
            // X-Ray: luminous technical blueprint cyan/white with translucent alpha
            half luma = dot(baseColor.rgb, half3(0.299h, 0.587h, 0.114h));
            baseColor.rgb = mix(half3(0.28h, 0.68h, 0.96h), half3(0.92h, 0.97h, 1.0h), clamp(luma, 0.0h, 1.0h));
            baseColor.a = clamp(baseColor.a * 0.28h, 0.04h, 0.35h);
        }

        baseColor.rgb *= half(uniforms.hdrGain);
        out.color = baseColor;

        float2 unitCorner = float2((vertexID & 1) ? 1.0f : -1.0f, (vertexID & 2) ? 1.0f : -1.0f);

        if (uniforms.renderMode == 0) {
            // 3D Gaussian Splat mode
            float s2 = uniforms.splatScale * uniforms.splatScale;
            packed_half3 covA = packed_half3(half(float(splat.covA.x) * s2), half(float(splat.covA.y) * s2), half(float(splat.covA.z) * s2));
            packed_half3 covB = packed_half3(half(float(splat.covB.x) * s2), half(float(splat.covB.y) * s2), half(float(splat.covB.z) * s2));
            float3 cov2D = calcCovariance2D(
                viewPos4.xyz,
                covA,
                covB,
                uniforms.modelViewMatrix,
                uniforms.projectionMatrix,
                uniforms.screenSize
            );
            float2 axis1, axis2;
            decomposeCovariance(cov2D, axis1, axis2);

            float2 relativeCoords = unitCorner * kBoundsRadius;
            float2 deltaScreen = (relativeCoords.x * axis1 + relativeCoords.y * axis2) * 2.0f / uniforms.screenSize;
            out.position = float4(
                clipCenter.x + deltaScreen.x * clipCenter.w,
                clipCenter.y + deltaScreen.y * clipCenter.w,
                clipCenter.z,
                clipCenter.w
            );
            out.relativePosition = half2(relativeCoords);
        } else {
            // Point Cloud / Crisp Surfel mode
            bool isOrtho = (abs(uniforms.projectionMatrix[3][3]) > 0.5f);
            float focalY = uniforms.projectionMatrix[1][1] * uniforms.screenSize.y * 0.5f;
            float radiusPx;
            if (isOrtho) {
                radiusPx = uniforms.pointRadiusMeters * focalY;
            } else {
                radiusPx = (uniforms.pointRadiusMeters * focalY) / max(0.05f, -viewPos4.z);
            }
            radiusPx = clamp(radiusPx, 1.35f, 18.0f);
            float2 deltaNDC = unitCorner * (radiusPx * 2.0f / uniforms.screenSize);
            out.position = float4(
                clipCenter.x + deltaNDC.x * clipCenter.w,
                clipCenter.y + deltaNDC.y * clipCenter.w,
                clipCenter.z,
                clipCenter.w
            );
            out.relativePosition = half2(unitCorner);
        }

        return out;
    }

    fragment half4 splatFragmentMain(FragmentIn in [[stage_in]]) {
        if (in.renderMode == 0) {
            half r2 = dot(in.relativePosition, in.relativePosition);
            if (r2 > half(kBoundsRadiusSquared)) {
                discard_fragment();
            }
            half alpha = in.color.a * exp(-0.5h * r2);
            if (alpha < kMinAlpha) {
                discard_fragment();
            }
            return half4(alpha * in.color.rgb, alpha);
        } else {
            half r2 = dot(in.relativePosition, in.relativePosition);
            if (r2 > 1.0h) {
                discard_fragment();
            }
            // Subtle spherical surfel shading so dense point clouds have crisp 3D depth relief
            half nz = sqrt(max(0.0h, 1.0h - r2));
            half domeShade = mix(0.82h, 1.06h, nz);
            half3 shadedRGB = in.color.rgb * domeShade;
            if (in.shadingMode == 2) {
                half alpha = in.color.a * (1.0h - 0.5h * r2);
                return half4(alpha * shadedRGB, alpha);
            }
            return half4(shadedRGB, 1.0h);
        }
    }
    """#
}
