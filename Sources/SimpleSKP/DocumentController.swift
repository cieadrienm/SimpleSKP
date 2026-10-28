import AppKit
import SimpleSKPCore
import UniformTypeIdentifiers

/// Opens `.skp`, `.dwg`, `.dxf`, `.dae`, and `.obj` files; no `defaultType`, so no untitled document can be made. `DocumentController()` made first becomes `NSDocumentController.shared`.
final class DocumentController: NSDocumentController {
    static let skpType = "com.sketchup.skp"
    static let dwgType = "com.autodesk.dwg"
    static let dxfType = "com.autodesk.dxf"
    static let daeType = "org.khronos.collada.digital-asset-exchange"
    static let objType = "public.geometry-definition-format"
    static let sskpType = "net.cieadrienm.sskp"
    static let allowedExtensions: Set<String> = ["skp", "dwg", "dxf", "dae", "obj", "sskp"]

    static let contentType = UTType(importedAs: skpType)
    static let dwgContentType = UTType(importedAs: dwgType)
    static let dxfContentType = UTType(importedAs: dxfType)
    static let daeContentType = UTType(importedAs: daeType)
    static let objContentType = UTType(importedAs: objType)
    static let sskpContentType = UTType(filenameExtension: "sskp") ?? UTType.json
    static let allowedContentTypes: [UTType] = {
        var types: [UTType] = [contentType, dwgContentType, dxfContentType, daeContentType, objContentType, sskpContentType]
        for ext in ["skp", "dwg", "dxf", "dae", "obj", "sskp"] {
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
        panel.message = L("Choisissez un ou plusieurs fichiers SketchUp (.skp), AutoCAD (.dwg, .dxf), Collada (.dae) ou Wavefront (.obj).",
                          "Choose one or more SketchUp (.skp), AutoCAD (.dwg, .dxf), Collada (.dae) or Wavefront (.obj) files.")
    }
}
