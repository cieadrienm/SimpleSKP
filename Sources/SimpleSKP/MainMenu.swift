import AppKit
import SimpleSKPCore
import SimpleSKPViewport

/// The application menu, in French or English, built in code (no nib). Document actions have no target:
/// they reach `SKPDocument` through the responder chain, so AppKit disables them without a window.
@MainActor
enum MainMenu {
    /// Camera menu order and ⌘1…⌘7, SketchUp's standard views.
    static let cameraViews: [(view: StandardView, title: String)] = [
        (.iso, L("Iso", "Iso")),
        (.top, L("Dessus", "Top")),
        (.front, L("Face", "Front")),
        (.right, L("Droite", "Right")),
        (.back, L("Arrière", "Back")),
        (.left, L("Gauche", "Left")),
        (.bottom, L("Dessous", "Bottom")),
    ]

    static func build(delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(applicationMenu(delegate))
        menu.addItem(fileMenu())
        menu.addItem(editMenu())
        menu.addItem(viewMenu())
        menu.addItem(cameraMenu())
        menu.addItem(windowMenu())
        menu.addItem(helpMenu(delegate))
        return menu
    }

    private static func applicationMenu(_ delegate: AppDelegate) -> NSMenuItem {
        let menu = NSMenu(title: "SimpleSKP")
        menu.add(L("À propos de SimpleSKP", "About SimpleSKP"), #selector(AppDelegate.showAbout(_:)), target: delegate)
        menu.add(L("Rechercher des mises à jour…", "Check for Updates…"), #selector(AppDelegate.checkForUpdates(_:)), target: delegate)
        menu.addItem(.separator())
        menu.add(L("Réglages…", "Settings…"), #selector(AppDelegate.showSettings(_:)), key: ",", target: delegate)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        menu.add("Services", nil).submenu = services
        menu.addItem(.separator())
        menu.add(L("Masquer SimpleSKP", "Hide SimpleSKP"), #selector(NSApplication.hide(_:)), key: "h")
        menu.add(L("Masquer les autres", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option])
        menu.add(L("Tout afficher", "Show All"), #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        menu.add(L("Quitter SimpleSKP", "Quit SimpleSKP"), #selector(NSApplication.terminate(_:)), key: "q")
        return menu.asItem()
    }

    /// AppKit inserts « Ouvrir l'élément récent » itself once the bundle declares document types (SimpleText D14).
    /// A viewer never saves back to `.skp`, but exporting a PNG screenshot is available.
    private static func fileMenu() -> NSMenuItem {
        let menu = NSMenu(title: L("Fichier", "File"))
        menu.add(L("Ouvrir…", "Open…"), #selector(NSDocumentController.openDocument(_:)), key: "o")
        menu.addItem(.separator())
        menu.add(L("Exporter l'image PNG…", "Export PNG Image…"), #selector(SKPDocument.exportImage(_:)), key: "e", modifiers: [.command, .shift])
        menu.add(L("Ouvrir dans SketchUp", "Open in SketchUp"), #selector(SKPDocument.openInSketchUp(_:)), key: "o", modifiers: [.command, .shift])
        menu.add(L("Afficher dans le Finder", "Show in Finder"), #selector(SKPDocument.revealInFinder(_:)))
        menu.addItem(.separator())
        menu.add(L("Fermer", "Close"), #selector(NSWindow.performClose(_:)), key: "w")
        return menu.asItem()
    }

    private static func editMenu() -> NSMenuItem {
        let menu = NSMenu(title: L("Édition", "Edit"))
        menu.add(L("Copier l'image", "Copy Image"), #selector(SKPDocument.copyImage(_:)), key: "c")
        return menu.asItem()
    }

    private static func viewMenu() -> NSMenuItem {
        let menu = NSMenu(title: L("Présentation", "View"))
        menu.add(L("Barre latérale", "Sidebar"), #selector(SKPDocument.toggleSidebarPanel(_:)), key: "s", modifiers: [.command, .option])
        menu.add(L("Arêtes", "Edges"), #selector(SKPDocument.toggleEdges(_:)), key: "e")
        menu.add(L("Grille et axes", "Grid and Axes"), #selector(SKPDocument.toggleGrid(_:)), key: "g", modifiers: [.command, .option])
        menu.add(L("Perspective / Parallèle", "Perspective / Parallel"), #selector(SKPDocument.togglePerspective(_:)), key: "p", modifiers: [.command, .option])
        menu.add(L("Ombres", "Shadows"), #selector(SKPDocument.toggleShadows(_:)), key: "o", modifiers: [.command, .option])
        menu.add(L("Éclairage ponctuel", "Point Lighting"), #selector(SKPDocument.toggleLightingMode(_:)), key: "l", modifiers: [.command, .option])
        menu.add(L("Occlusion ambiante", "Ambient Occlusion"), #selector(SKPDocument.toggleAmbientOcclusion(_:)), key: "a", modifiers: [.command, .option])
        menu.addItem(.separator())
        let styles: [(ShadingStyle, String)] = [
            (.textured, L("Style : Texturé (PBR)", "Style: Textured (PBR)")),
            (.clay, L("Style : Maquette blanche", "Style: White Clay")),
            (.xray, L("Style : Rayons X", "Style: X-Ray")),
            (.wireframe, L("Style : Filaire", "Style: Wireframe")),
        ]
        for (index, entry) in styles.enumerated() {
            menu.add(entry.1, #selector(SKPDocument.selectShadingStyle(_:)), tag: index)
        }
        menu.addItem(.separator())
        menu.add(L("Réinitialiser la vue", "Reset View"), #selector(SKPDocument.resetView(_:)), key: "z", modifiers: [])
        menu.add(L("Zoom étendu", "Zoom Extents"), #selector(SKPDocument.zoomExtents(_:)), key: "z", modifiers: [.shift])
        menu.add(L("Mode vol libre", "Free Fly Mode"), #selector(SKPDocument.toggleFreeFlight(_:)), key: "f", modifiers: [.command, .option])
        menu.addItem(.separator())
        menu.add(L("Scène précédente", "Previous Scene"), #selector(SKPDocument.previousScene(_:)), key: "[")
        menu.add(L("Scène suivante", "Next Scene"), #selector(SKPDocument.nextScene(_:)), key: "]")
        // AppKit appends « Activer le mode plein écran » itself (SimpleText D14).
        return menu.asItem()
    }

    private static func cameraMenu() -> NSMenuItem {
        let menu = NSMenu(title: L("Caméra", "Camera"))
        for (index, entry) in cameraViews.enumerated() {
            menu.add(entry.title, #selector(SKPDocument.lookStandard(_:)), key: "\(index + 1)", tag: index)
        }
        return menu.asItem()
    }

    private static func windowMenu() -> NSMenuItem {
        let menu = NSMenu(title: L("Fenêtre", "Window"))
        menu.add(L("Réduire", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), key: "m")
        menu.add("Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        menu.add(L("Tout ramener au premier plan", "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)))
        NSApp.windowsMenu = menu
        return menu.asItem()
    }

    private static func helpMenu(_ delegate: AppDelegate) -> NSMenuItem {
        let menu = NSMenu(title: L("Aide", "Help"))
        menu.add(L("Aide SimpleSKP", "SimpleSKP Help"), #selector(AppDelegate.showHelp(_:)), key: "?", target: delegate)
        menu.add(L("Raccourcis clavier", "Keyboard Shortcuts"), #selector(AppDelegate.showShortcuts(_:)), key: "/", target: delegate)
        NSApp.helpMenu = menu
        return menu.asItem()
    }
}

extension NSMenu {
    @discardableResult
    func add(
        _ title: String,
        _ action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command,
        tag: Int = 0,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        item.target = target
        addItem(item)
        return item
    }

    func asItem() -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = self
        return item
    }
}
