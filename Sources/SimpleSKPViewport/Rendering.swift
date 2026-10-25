import SceneKit

/// Rendering setup shared by the scene builder and the view (D7 « réaliste doux »). Owned by the rendering agent;
/// the view only calls these two functions.
public enum Rendering {
    /// Camera post-processing: HDR without exposure adaptation, screen-space ambient occlusion, no bloom/blur.
    public static func configure(camera: SCNCamera) {
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false
        camera.automaticallyAdjustsZRange = true
        setAmbientOcclusion(true, on: camera)
    }

    /// Toggles screen-space ambient occlusion (intensity 1 when on, 0 when off).
    public static func setAmbientOcclusion(_ enabled: Bool, on camera: SCNCamera) {
        camera.screenSpaceAmbientOcclusionIntensity = enabled ? 1 : 0
    }
}
