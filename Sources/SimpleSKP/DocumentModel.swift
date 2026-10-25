import AppKit
import Observation
import SceneKit
import SimpleSKPCore
import SimpleSKPViewport

/// State of one open `.skp`: header first, then the loaded model and its scene. Owns the viewport so the
/// menu actions reach it. Every viewport call is guarded by `.ready`: before that there is no scene.
@Observable
@MainActor
final class DocumentModel {
    enum State {
        case loading(SKPReader.Progress?)
        case ready(ViewportScene)
        case failed(Error)
    }

    var info: SKPFileInfo? {
        didSet { thumbnail = info?.thumbnailPNG.flatMap(NSImage.init(data:)) }
    }
    private(set) var thumbnail: NSImage?
    var state: State = .loading(nil)
    /// Set as soon as the reader returns, before the scene exists.
    private(set) var skp: SKPModel?
    @ObservationIgnored let viewport = ViewportView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    var selectedScene: Int?
    var layerVisible: [Bool] = []
    var showsEdges = Preferences.showsEdges
    var isPerspective = Preferences.isPerspective
    var showSidebar = false
    var loadSeconds: Double?

    var scene: ViewportScene? {
        if case .ready(let scene) = state { return scene }
        return nil
    }

    var isReady: Bool { scene != nil }

    var error: Error? {
        if case .failed(let error) = state { return error }
        return nil
    }

    // MARK: Loading

    func setModel(_ model: SKPModel) {
        skp = model
        layerVisible = model.layers.map(\.isVisible)
        showSidebar = Preferences.showSidebar && (!model.scenes.isEmpty || model.layers.count > 1)
    }

    /// Main thread, once the scene is built off-main.
    func present(_ scene: ViewportScene, seconds: Double) {
        setModel(scene.model)
        loadSeconds = seconds
        if !showsEdges { scene.showsEdges = false }
        state = .ready(scene)
        viewport.present(scene)
        if scene.model.camera == nil, viewport.isPerspective != isPerspective {
            viewport.isPerspective = isPerspective
        }
        isPerspective = viewport.isPerspective
    }

    func fail(_ error: Error) {
        state = .failed(error)
    }

    // MARK: Actions

    func selectScene(_ index: Int) {
        guard let skp, skp.scenes.indices.contains(index) else { return }
        selectedScene = index
        let hidden = Set(skp.scenes[index].hiddenLayers)
        for layer in layerVisible.indices {
            let visible = !hidden.contains(layer)
            guard layerVisible[layer] != visible else { continue }   // a hall has 150 layers: touch only changes
            layerVisible[layer] = visible
            scene?.setLayer(layer, visible: visible)
        }
        if isReady, let camera = skp.scenes[index].camera {
            viewport.apply(camera: camera, animated: true)
            isPerspective = camera.isPerspective
        }
    }

    func previousScene() {
        guard let count = skp?.scenes.count, count > 0 else { return }
        selectScene(((selectedScene ?? 0) - 1 + count) % count)
    }

    func nextScene() {
        guard let count = skp?.scenes.count, count > 0 else { return }
        selectScene(((selectedScene ?? -1) + 1) % count)
    }

    func toggleLayer(_ index: Int) {
        guard layerVisible.indices.contains(index) else { return }
        layerVisible[index].toggle()
        scene?.setLayer(index, visible: layerVisible[index])
    }

    func zoomExtents() {
        if isReady { viewport.zoomExtents(animated: true) }
    }

    func look(_ view: StandardView) {
        if isReady { viewport.look(view, animated: true) }
    }

    func togglePerspective() {
        isPerspective.toggle()
        Preferences.isPerspective = isPerspective
        if isReady { viewport.isPerspective = isPerspective }
    }

    func toggleEdges() {
        showsEdges.toggle()
        Preferences.showsEdges = showsEdges
        scene?.showsEdges = showsEdges
    }

    func toggleSidebar() {
        showSidebar.toggle()
        Preferences.showSidebar = showSidebar
    }

    func copyImage() {
        guard isReady, let png = Snapshot.png(of: viewport.snapshot()) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
    }

    /// The installed SketchUp that opens this file (nil without one): the one the framework came from when it is a
    /// SketchUp.app, else any SketchUp registered for `.skp` (the default app may be SimpleSKP itself).
    var sketchUpApp: URL? {
        guard let url = info?.url else { return nil }
        let host = SketchUpAPI.locate()?.frameworkURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if let host, host.pathExtension == "app", host.lastPathComponent.hasPrefix("SketchUp") { return host }
        return NSWorkspace.shared.urlsForApplications(toOpen: url).first { $0.lastPathComponent.hasPrefix("SketchUp") }
    }

    func openInSketchUp() {
        guard let url = info?.url, let app = sketchUpApp else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealInFinder() {
        if let url = info?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    // MARK: Status bar

    /// Left part of the status bar: the file's numbers once read, else the loading phase or the error.
    var statusText: String {
        if let error { return error.localizedDescription }
        if let skp {
            let size = skp.size
            let parts: [String?] = [
                info?.versionLabel ?? skp.fileInfo.versionLabel,
                Format.count(skp.stats.faces, L("face", "face")),
                Format.count(skp.stats.edges, L("arête", "edge")),
                Format.count(skp.stats.instances, L("composant", "component")),
                "\(Format.decimal(size.x)) × \(Format.decimal(size.y)) × \(Format.decimal(size.z)) m",
            ]
            return parts.compactMap { $0 }.joined(separator: " · ")
        }
        var text = L("Chargement…", "Loading…")
        if case .loading(let progress?) = state {
            text += " \(progress.phase) · " + Format.count(progress.faces, L("face", "face"))
        }
        return text
    }
}

/// Numbers in the interface language: French groups thousands with a narrow no-break space and uses a comma.
@MainActor
enum Format {
    private static var formatters: [String: NumberFormatter] = [:]

    private static func formatter(decimals: Int) -> NumberFormatter {
        let key = "\(Localization.current.resolvedCode)-\(decimals)"
        if let formatter = formatters[key] { return formatter }
        let formatter = NumberFormatter()
        formatter.locale = Localization.current.locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        if !Localization.isEnglish { formatter.groupingSeparator = "\u{202F}" }
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatters[key] = formatter
        return formatter
    }

    static func integer(_ value: Int) -> String {
        formatter(decimals: 0).string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func decimal<T: BinaryFloatingPoint>(_ value: T) -> String {
        formatter(decimals: 1).string(from: NSNumber(value: Double(value))) ?? "\(value)"
    }

    /// "184 320 faces", "1 face", "0 face" in French, "0 faces" in English.
    static func count(_ value: Int, _ singular: String) -> String {
        "\(integer(value)) \(singular)\(Localization.isEnglish ? (value == 1 ? "" : "s") : (value > 1 ? "s" : ""))"
    }

    /// "1,9 s".
    static func seconds(_ value: Double) -> String {
        "\(decimal(value)) s"
    }
}
