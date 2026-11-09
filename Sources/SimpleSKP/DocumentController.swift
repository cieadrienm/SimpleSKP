import AppKit
import SimpleSKPCore
import UniformTypeIdentifiers

/// Opens `.skp`, `.dwg`, `.dxf`, `.dae`, `.obj`, `.fbx`, Gaussian Splat (`.ply`, `.splat`, `.spz`), and Point Cloud (`.xyz`, `.pts`, `.pcd`) files; no `defaultType`, so no untitled document can be made. `DocumentController()` made first becomes `NSDocumentController.shared`.
final class DocumentController: NSDocumentController {
    static let skpType = "com.sketchup.skp"
    static let dwgType = "com.autodesk.dwg"
    static let dxfType = "com.autodesk.dxf"
    static let daeType = "org.khronos.collada.digital-asset-exchange"
    static let objType = "public.geometry-definition-format"
    static let fbxType = "com.autodesk.fbx"
    static let glbType = "org.khronos.glb"
    static let gltfType = "org.khronos.gltf"
    static let plyType = "public.polygon-file-format"
    static let splatType = "net.cieadrienm.splat"
    static let spzType = "net.cieadrienm.spz"
    static let xyzType = "public.xyz-point-cloud"
    static let ptsType = "net.cieadrienm.pts"
    static let pcdType = "net.cieadrienm.pcd"
    static let sskpType = "net.cieadrienm.sskp"
    static let allowedExtensions: Set<String> = [
        "skp", "dwg", "dxf", "dae", "obj", "fbx", "glb", "gltf",
        "ply", "splat", "spz", "xyz", "pts", "pcd",
        "sskp",
    ]

    static let contentType = UTType(importedAs: skpType)
    static let dwgContentType = UTType(importedAs: dwgType)
    static let dxfContentType = UTType(importedAs: dxfType)
    static let daeContentType = UTType(importedAs: daeType)
    static let objContentType = UTType(importedAs: objType)
    static let fbxContentType = UTType(importedAs: fbxType)
    static let glbContentType = UTType(filenameExtension: "glb") ?? UTType(importedAs: glbType)
    static let gltfContentType = UTType(filenameExtension: "gltf") ?? UTType(importedAs: gltfType)
    static let plyContentType = UTType(importedAs: plyType)
    static let splatContentType = UTType(filenameExtension: "splat") ?? UTType(importedAs: splatType)
    static let spzContentType = UTType(filenameExtension: "spz") ?? UTType(importedAs: spzType)
    static let xyzContentType = UTType(filenameExtension: "xyz") ?? UTType(importedAs: xyzType)
    static let ptsContentType = UTType(filenameExtension: "pts") ?? UTType(importedAs: ptsType)
    static let pcdContentType = UTType(filenameExtension: "pcd") ?? UTType(importedAs: pcdType)
    static let sskpContentType = UTType(filenameExtension: "sskp") ?? UTType.json
    static let allowedContentTypes: [UTType] = {
        var types: [UTType] = [
            contentType, dwgContentType, dxfContentType, daeContentType, objContentType,
            fbxContentType, glbContentType, gltfContentType, plyContentType, splatContentType, spzContentType,
            xyzContentType, ptsContentType, pcdContentType, sskpContentType,
        ]
        for ext in allowedExtensions {
            if let ut = UTType(filenameExtension: ext), !types.contains(ut) {
                types.append(ut)
            }
        }
        return types
    }()

    /// Without an Info.plist (`swift run`, tests) AppKit knows no document class and disables « Ouvrir… ».
    override var documentClassNames: [String] { [NSStringFromClass(SKPDocument.self)] }

    override func documentClass(forType typeName: String) -> AnyClass? {
        SKPDocument.self
    }

    /// By extension: run from `swift run` there is no Info.plist to declare the type.
    override func typeForContents(of url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "skp": return Self.skpType
        case "dwg": return Self.dwgType
        case "dxf": return Self.dxfType
        case "dae": return Self.daeType
        case "obj": return Self.objType
        case "fbx": return Self.fbxType
        case "glb": return Self.glbType
        case "gltf": return Self.gltfType
        case "ply": return Self.plyType
        case "splat": return Self.splatType
        case "spz": return Self.spzType
        case "xyz": return Self.xyzType
        case "pts": return Self.ptsType
        case "pcd": return Self.pcdType
        case "sskp": return Self.sskpType
        default: return try super.typeForContents(of: url)
        }
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?, completionHandler: @escaping (Int) -> Void) {
        configurePanel(openPanel)
        super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
    }

    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        configurePanel(openPanel)
        return super.runModalOpenPanel(openPanel, forTypes: nil)
    }

    func configurePanel(_ panel: NSOpenPanel) {
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.allowedContentTypes
        panel.message = L("Choisissez un ou plusieurs fichiers 3D (.skp, .dwg, .dxf, .dae, .obj, .fbx, .glb, .gltf), Gaussian Splats (.ply, .splat, .spz) ou Nuages de points (.xyz, .pts, .pcd).",
                          "Choose one or more 3D files (.skp, .dwg, .dxf, .dae, .obj, .fbx, .glb, .gltf), Gaussian Splats (.ply, .splat, .spz) or Point Clouds (.xyz, .pts, .pcd).")
    }
}
