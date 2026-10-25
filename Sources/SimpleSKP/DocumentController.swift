import AppKit
import SimpleSKPCore
import UniformTypeIdentifiers

/// Opens `.skp` files only; no `defaultType`, so no untitled document can be made. `DocumentController()` made first becomes `NSDocumentController.shared`.
final class DocumentController: NSDocumentController {
    static let skpType = "com.sketchup.skp"
    static let contentType = UTType(importedAs: skpType)

    /// Without an Info.plist (`swift run`, tests) AppKit knows no document class and disables « Ouvrir… ».
    override var documentClassNames: [String] { [NSStringFromClass(SKPDocument.self)] }

    override func documentClass(forType typeName: String) -> AnyClass? {
        SKPDocument.self
    }

    /// By extension: run from `swift run` there is no Info.plist to declare the type.
    override func typeForContents(of url: URL) throws -> String {
        if url.pathExtension.lowercased() == "skp" { return Self.skpType }
        return try super.typeForContents(of: url)
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
        panel.allowedContentTypes = [Self.contentType]
        panel.message = L("Choisissez un ou plusieurs fichiers SketchUp (.skp).", "Choose one or more SketchUp files (.skp).")
    }
}
