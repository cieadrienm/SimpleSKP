import SceneKit

/// Rendering setup shared by the scene builder and the view (D7 « réaliste doux »). The view calls `configure(camera:)`
/// and `setAmbientOcclusion(_:on:)`; the scene uses `skyImage()` as background and lighting environment.
public enum Rendering {
    /// Camera post-processing: HDR without exposure adaptation, screen-space ambient occlusion, no bloom/blur/fringe.
    public static func configure(camera: SCNCamera) {
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.exposureOffset = -0.5
        camera.automaticallyAdjustsZRange = true
        camera.screenSpaceAmbientOcclusionRadius = 0.4
        camera.screenSpaceAmbientOcclusionBias = 0.03
        camera.screenSpaceAmbientOcclusionDepthThreshold = 0.3
        camera.bloomIntensity = 0
        camera.motionBlurIntensity = 0
        camera.colorFringeIntensity = 0
        setAmbientOcclusion(true, on: camera)
    }

    /// Toggles screen-space ambient occlusion (intensity 1 when on, 0 when off). SceneKit's SSAO assumes a perspective
    /// depth buffer: in a parallel projection it blackens whole faces and streaks floors, so it stays off there —
    /// call again after switching projection.
    public static func setAmbientOcclusion(_ enabled: Bool, on camera: SCNCamera) {
        camera.screenSpaceAmbientOcclusionIntensity = enabled && !camera.usesOrthographicProjection ? 1 : 0
    }

    /// Procedural sky, equirectangular 512 × 256 (top row = zenith): soft blue zenith, warm white horizon, grey ground.
    /// The lighting environment. `backdrop: true` gives the upper half alone as a 4 × 256 strip, which SceneKit draws
    /// as a screen-space background: models are mostly seen from above, where the sphere would show only the grey ground.
    public static func skyImage(backdrop: Bool = false) -> CGImage {
        let (w, h) = backdrop ? (4, 256) : (512, 256)
        let zenith = SIMD3<Float>(0.55, 0.70, 0.90), horizon = SIMD3<Float>(0.95, 0.94, 0.90), ground = SIMD3<Float>(0.35, 0.36, 0.38)
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            let elevation = (backdrop ? 1 - (Float(y) + 0.5) / Float(h) : 0.5 - (Float(y) + 0.5) / Float(h)) * .pi / (backdrop ? 2 : 1)
            let c = elevation >= 0
                ? simd_mix(horizon, zenith, SIMD3(repeating: pow(sin(elevation), 0.6)))
                : simd_mix(horizon, ground, SIMD3(repeating: min(1, -elevation / 0.15))) // short soft edge below the horizon
            for x in 0..<w {
                let o = (y * w + x) * 4
                pixels[o] = UInt8(c.x * 255); pixels[o + 1] = UInt8(c.y * 255); pixels[o + 2] = UInt8(c.z * 255)
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    }
}
