import Foundation

// Layouts transcribed from SketchUpAPI headers (geometry.h, color.h). Never SIMD3<Double>: its stride is 32 bytes.
struct SUPoint3D { var x = 0.0, y = 0.0, z = 0.0 }
struct SUColor { var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 0 }

/// `SU*Ref` is `struct { void* ptr; }`: passed by value as a raw pointer, by address as a pointer to one.
typealias Ref = UnsafeMutableRawPointer?
typealias OutRef = UnsafeMutablePointer<UnsafeMutableRawPointer?>

extension SketchUpAPI {
    typealias Count = @convention(c) (Ref, UnsafeMutablePointer<Int>) -> Int32
    typealias List = @convention(c) (Ref, Int, OutRef, UnsafeMutablePointer<Int>) -> Int32
    typealias GetRef = @convention(c) (Ref, OutRef) -> Int32
    typealias GetBool = @convention(c) (Ref, UnsafeMutablePointer<Bool>) -> Int32
    /// Also `SUTransformation*` (`double values[16]`).
    typealias GetDouble = @convention(c) (Ref, UnsafeMutablePointer<Double>) -> Int32
    typealias Release = @convention(c) (OutRef) -> Int32
    /// `SUPoint3D[]` and `SUVector3D[]` (same layout); struct pointers are raw (Swift structs are not C-representable).
    typealias Points = @convention(c) (Ref, Int, UnsafeMutableRawPointer, UnsafeMutablePointer<Int>) -> Int32

    /// The C functions SimpleSKP calls, resolved once with `dlsym` (all present in SketchUp 2023, API 11.0).
    struct Functions: @unchecked Sendable {
        let SUInitialize: @convention(c) () -> Void
        let SUStringCreate: Release
        let SUStringGetUTF8Length: Count
        let SUStringGetUTF8: @convention(c) (Ref, Int, UnsafeMutablePointer<CChar>, UnsafeMutablePointer<Int>) -> Int32
        let SUStringRelease: Release
        let SUModelCreate: Release
        let SUModelCreateFromFileWithStatus: @convention(c) (OutRef, UnsafePointer<CChar>, UnsafeMutablePointer<Int32>) -> Int32
        let SUModelRelease: Release
        let SUModelGetEntities: GetRef
        let SUModelGetNumMaterials: Count
        let SUModelGetMaterials: List
        let SUModelGetNumLayers: Count
        let SUModelGetLayers: List
        let SUModelGetNumScenes: Count
        let SUModelGetScenes: List
        let SUModelGetCamera: GetRef
        let SUMaterialGetName: GetRef
        let SUMaterialGetColor: @convention(c) (Ref, UnsafeMutableRawPointer) -> Int32
        let SUMaterialGetOpacity: GetDouble
        let SUMaterialGetUseOpacity: GetBool
        let SUMaterialIsDrawnTransparent: GetBool?
        let SUMaterialGetType: @convention(c) (Ref, UnsafeMutablePointer<Int32>) -> Int32
        let SUMaterialGetTexture: GetRef
        let SUTextureGetFileName: GetRef
        let SUTextureWriteToFile: @convention(c) (Ref, UnsafePointer<CChar>) -> Int32
        let SUTextureGetDimensions: @convention(c) (Ref, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Double>, UnsafeMutablePointer<Double>) -> Int32
        let SULayerGetName: GetRef
        let SULayerGetMaterial: GetRef?
        let SULayerGetVisibility: GetBool
        let SULayerGetParentLayerFolder: GetRef?
        let SULayerFolderGetName: GetRef?
        let SUEntitiesGetNumFaces: Count
        let SUEntitiesGetFaces: List
        let SUEntitiesGetNumEdges: @convention(c) (Ref, Bool, UnsafeMutablePointer<Int>) -> Int32
        let SUEntitiesGetEdges: @convention(c) (Ref, Bool, Int, OutRef, UnsafeMutablePointer<Int>) -> Int32
        let SUEntitiesGetNumGroups: Count
        let SUEntitiesGetGroups: List
        let SUEntitiesGetNumInstances: Count
        let SUEntitiesGetInstances: List
        let SUEntitiesGetNumGuidePoints: Count?
        let SUEntitiesGetGuidePoints: List?
        let SUGuidePointGetPosition: (@convention(c) (Ref, UnsafeMutableRawPointer) -> Int32)?
        let SUDrawingElementGetHidden: GetBool
        let SUDrawingElementGetLayer: GetRef
        let SUDrawingElementGetMaterial: GetRef
        let SUMeshHelperCreate: @convention(c) (OutRef, Ref) -> Int32
        let SUMeshHelperGetNumTriangles: Count
        let SUMeshHelperGetNumVertices: Count
        let SUMeshHelperGetVertices: Points
        let SUMeshHelperGetNormals: Points
        let SUMeshHelperGetVertexIndices: @convention(c) (Ref, Int, UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>) -> Int32
        let SUMeshHelperGetFrontSTQCoords: Points
        let SUMeshHelperGetBackSTQCoords: Points
        let SUMeshHelperRelease: Release
        let SUFaceGetFrontMaterial: GetRef
        let SUFaceGetBackMaterial: GetRef
        let SUEdgeGetSoft: GetBool
        let SUEdgeGetStartVertex: GetRef
        let SUEdgeGetEndVertex: GetRef
        let SUVertexGetPosition: @convention(c) (Ref, UnsafeMutableRawPointer) -> Int32
        let SUGroupGetEntities: GetRef
        let SUGroupGetTransform: GetDouble
        let SUGroupGetName: GetRef
        let SUComponentInstanceGetDefinition: GetRef
        let SUComponentInstanceGetTransform: GetDouble
        let SUComponentInstanceGetName: GetRef
        let SUComponentDefinitionGetName: GetRef
        let SUComponentDefinitionGetEntities: GetRef
        let SUSceneGetName: GetRef
        let SUSceneGetUseCamera: GetBool
        let SUSceneGetCamera: GetRef
        let SUSceneGetUseHiddenLayers: GetBool
        let SUSceneGetNumLayers: Count
        let SUSceneGetLayers: List
        let SUCameraGetOrientation: @convention(c) (Ref, UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
        let SUCameraGetPerspective: GetBool
        let SUCameraGetPerspectiveFrustumFOV: GetDouble
        let SUCameraGetFOVIsHeight: GetBool
        let SUCameraGetAspectRatio: GetDouble
        let SUCameraGetOrthographicFrustumHeight: GetDouble

        init(handle: UnsafeMutableRawPointer) throws {
            func sym<T>(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> T {
                guard let p = dlsym(handle, name) else { throw SKPError.api(function: name, code: -1) }
                return unsafeBitCast(p, to: T.self)
            }
            func symOpt<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
                guard let p = dlsym(handle, name) else { return nil }
                return unsafeBitCast(p, to: T.self)
            }
            SUInitialize = try sym(handle, "SUInitialize")
            SUStringCreate = try sym(handle, "SUStringCreate")
            SUStringGetUTF8Length = try sym(handle, "SUStringGetUTF8Length")
            SUStringGetUTF8 = try sym(handle, "SUStringGetUTF8")
            SUStringRelease = try sym(handle, "SUStringRelease")
            SUModelCreate = try sym(handle, "SUModelCreate")
            SUModelCreateFromFileWithStatus = try sym(handle, "SUModelCreateFromFileWithStatus")
            SUModelRelease = try sym(handle, "SUModelRelease")
            SUModelGetEntities = try sym(handle, "SUModelGetEntities")
            SUModelGetNumMaterials = try sym(handle, "SUModelGetNumMaterials")
            SUModelGetMaterials = try sym(handle, "SUModelGetMaterials")
            SUModelGetNumLayers = try sym(handle, "SUModelGetNumLayers")
            SUModelGetLayers = try sym(handle, "SUModelGetLayers")
            SUModelGetNumScenes = try sym(handle, "SUModelGetNumScenes")
            SUModelGetScenes = try sym(handle, "SUModelGetScenes")
            SUModelGetCamera = try sym(handle, "SUModelGetCamera")
            SUMaterialGetName = try sym(handle, "SUMaterialGetName")
            SUMaterialGetColor = try sym(handle, "SUMaterialGetColor")
            SUMaterialGetOpacity = try sym(handle, "SUMaterialGetOpacity")
            SUMaterialGetUseOpacity = try sym(handle, "SUMaterialGetUseOpacity")
            SUMaterialIsDrawnTransparent = symOpt(handle, "SUMaterialIsDrawnTransparent")
            SUMaterialGetType = try sym(handle, "SUMaterialGetType")
            SUMaterialGetTexture = try sym(handle, "SUMaterialGetTexture")
            SUTextureGetFileName = try sym(handle, "SUTextureGetFileName")
            SUTextureWriteToFile = try sym(handle, "SUTextureWriteToFile")
            SUTextureGetDimensions = try sym(handle, "SUTextureGetDimensions")
            SULayerGetName = try sym(handle, "SULayerGetName")
            SULayerGetMaterial = symOpt(handle, "SULayerGetMaterial")
            SULayerGetVisibility = try sym(handle, "SULayerGetVisibility")
            SULayerGetParentLayerFolder = symOpt(handle, "SULayerGetParentLayerFolder")
            SULayerFolderGetName = symOpt(handle, "SULayerFolderGetName")
            SUEntitiesGetNumFaces = try sym(handle, "SUEntitiesGetNumFaces")
            SUEntitiesGetFaces = try sym(handle, "SUEntitiesGetFaces")
            SUEntitiesGetNumEdges = try sym(handle, "SUEntitiesGetNumEdges")
            SUEntitiesGetEdges = try sym(handle, "SUEntitiesGetEdges")
            SUEntitiesGetNumGroups = try sym(handle, "SUEntitiesGetNumGroups")
            SUEntitiesGetGroups = try sym(handle, "SUEntitiesGetGroups")
            SUEntitiesGetNumInstances = try sym(handle, "SUEntitiesGetNumInstances")
            SUEntitiesGetInstances = try sym(handle, "SUEntitiesGetInstances")
            SUEntitiesGetNumGuidePoints = symOpt(handle, "SUEntitiesGetNumGuidePoints")
            SUEntitiesGetGuidePoints = symOpt(handle, "SUEntitiesGetGuidePoints")
            SUGuidePointGetPosition = symOpt(handle, "SUGuidePointGetPosition")
            SUDrawingElementGetHidden = try sym(handle, "SUDrawingElementGetHidden")
            SUDrawingElementGetLayer = try sym(handle, "SUDrawingElementGetLayer")
            SUDrawingElementGetMaterial = try sym(handle, "SUDrawingElementGetMaterial")
            SUMeshHelperCreate = try sym(handle, "SUMeshHelperCreate")
            SUMeshHelperGetNumTriangles = try sym(handle, "SUMeshHelperGetNumTriangles")
            SUMeshHelperGetNumVertices = try sym(handle, "SUMeshHelperGetNumVertices")
            SUMeshHelperGetVertices = try sym(handle, "SUMeshHelperGetVertices")
            SUMeshHelperGetNormals = try sym(handle, "SUMeshHelperGetNormals")
            SUMeshHelperGetVertexIndices = try sym(handle, "SUMeshHelperGetVertexIndices")
            SUMeshHelperGetFrontSTQCoords = try sym(handle, "SUMeshHelperGetFrontSTQCoords")
            SUMeshHelperGetBackSTQCoords = try sym(handle, "SUMeshHelperGetBackSTQCoords")
            SUMeshHelperRelease = try sym(handle, "SUMeshHelperRelease")
            SUFaceGetFrontMaterial = try sym(handle, "SUFaceGetFrontMaterial")
            SUFaceGetBackMaterial = try sym(handle, "SUFaceGetBackMaterial")
            SUEdgeGetSoft = try sym(handle, "SUEdgeGetSoft")
            SUEdgeGetStartVertex = try sym(handle, "SUEdgeGetStartVertex")
            SUEdgeGetEndVertex = try sym(handle, "SUEdgeGetEndVertex")
            SUVertexGetPosition = try sym(handle, "SUVertexGetPosition")
            SUGroupGetEntities = try sym(handle, "SUGroupGetEntities")
            SUGroupGetTransform = try sym(handle, "SUGroupGetTransform")
            SUGroupGetName = try sym(handle, "SUGroupGetName")
            SUComponentInstanceGetDefinition = try sym(handle, "SUComponentInstanceGetDefinition")
            SUComponentInstanceGetTransform = try sym(handle, "SUComponentInstanceGetTransform")
            SUComponentInstanceGetName = try sym(handle, "SUComponentInstanceGetName")
            SUComponentDefinitionGetName = try sym(handle, "SUComponentDefinitionGetName")
            SUComponentDefinitionGetEntities = try sym(handle, "SUComponentDefinitionGetEntities")
            SUSceneGetName = try sym(handle, "SUSceneGetName")
            SUSceneGetUseCamera = try sym(handle, "SUSceneGetUseCamera")
            SUSceneGetCamera = try sym(handle, "SUSceneGetCamera")
            SUSceneGetUseHiddenLayers = try sym(handle, "SUSceneGetUseHiddenLayers")
            SUSceneGetNumLayers = try sym(handle, "SUSceneGetNumLayers")
            SUSceneGetLayers = try sym(handle, "SUSceneGetLayers")
            SUCameraGetOrientation = try sym(handle, "SUCameraGetOrientation")
            SUCameraGetPerspective = try sym(handle, "SUCameraGetPerspective")
            SUCameraGetPerspectiveFrustumFOV = try sym(handle, "SUCameraGetPerspectiveFrustumFOV")
            SUCameraGetFOVIsHeight = try sym(handle, "SUCameraGetFOVIsHeight")
            SUCameraGetAspectRatio = try sym(handle, "SUCameraGetAspectRatio")
            SUCameraGetOrthographicFrustumHeight = try sym(handle, "SUCameraGetOrthographicFrustumHeight")
        }
    }
}
