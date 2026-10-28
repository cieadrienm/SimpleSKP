import Foundation
import simd

/// Reads AutoCAD `.dwg` and `.dxf` files into an `SKPModel`.
/// Uses SketchUp's ODA Teigha `DWGImporter.plugin` when available (converting `.dwg`/`.dxf` to a temporary `.skp`
/// with automatic metric unit and geodetic origin normalization), and includes a native Swift ASCII `.dxf` parser fallback.
public enum CADReader {
    public static func load(
        _ url: URL,
        fileInfo: SKPFileInfo? = nil,
        progress: (@Sendable (SKPReader.Progress) -> Void)? = nil,
        isCancelled: @Sendable () -> Bool = { false }
    ) throws -> SKPModel {
        let info = try fileInfo ?? SKPFileInfo.read(url)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw SKPError.unreadable(url)
        }
        if isCancelled() { throw SKPError.cancelled }

        let start = Date()
        progress?(SKPReader.Progress(phase: L("Conversion AutoCAD…", "Converting AutoCAD…"), faces: 0, fraction: 0.12))

        let forceNativeDXF = getenv("SIMPLESKP_FORCE_NATIVE_DXF") != nil
        if !forceNativeDXF, let plugin = locatePlugin() {
            do {
                var model = try loadViaPlugin(url: url, fileInfo: info, plugin: plugin, progress: progress, isCancelled: isCancelled)
                model.stats.loadSeconds = Date().timeIntervalSince(start)
                return model
            } catch let error as SKPError {
                if case .cancelled = error { throw error }
                if !info.isDXF { throw error }
            } catch {
                if !info.isDXF { throw SKPError.unreadable(url) }
            }
        }

        if info.isDXF {
            var model = try DXFNativeParser.parse(url: url, fileInfo: info, progress: progress, isCancelled: isCancelled)
            model = normalizeCADModel(model)
            model.stats.loadSeconds = Date().timeIntervalSince(start)
            return model
        }

        throw SKPError.unreadable(url)
    }

    // MARK: - ODA DWGImporter.plugin Integration

    struct PluginLocation {
        let binaryURL: URL
        let frameworksDir: URL
    }

    static func locatePlugin() -> PluginLocation? {
        func env(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }
        let fm = FileManager.default
        var candidates: [PluginLocation] = []

        // 1. Bundled inside SimpleSKP.app
        let bundledPlugin = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/DWGImporter.plugin/Contents/MacOS/DWGImporter")
        let bundledFW = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks")
        candidates.append(PluginLocation(binaryURL: bundledPlugin, frameworksDir: bundledFW))

        if env("SIMPLESKP_BUNDLED_SDK_ONLY") == nil {
            // 2. Installed SketchUp.app bundles in /Applications and ~/Applications
            var apps: [URL] = []
            for base in [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
                let entries = (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
                for entry in entries where entry.lastPathComponent.hasPrefix("SketchUp") {
                    if entry.pathExtension == "app" {
                        apps.append(entry)
                    } else {
                        let sub = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil)) ?? []
                        apps += sub.filter { $0.lastPathComponent.hasPrefix("SketchUp") && $0.pathExtension == "app" }
                    }
                }
            }
            apps.sort {
                let v0 = Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                let v1 = Bundle(url: $1)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                return v0.compare(v1, options: .numeric) == .orderedDescending
            }
            for app in apps {
                candidates.append(PluginLocation(
                    binaryURL: app.appendingPathComponent("Contents/PlugIns/DWGImporter.plugin/Contents/MacOS/DWGImporter"),
                    frameworksDir: app.appendingPathComponent("Contents/Frameworks")
                ))
            }
        }

        return candidates.first { fm.fileExists(atPath: $0.binaryURL.path) }
    }

    private struct StdStringView {
        var data: UnsafePointer<CChar>
        var size: UInt64
        var capacityAndFlag: UInt64
    }

    private struct StdWStringView {
        var data: UnsafePointer<UInt32>
        var size: UInt64
        var capacityAndFlag: UInt64
    }

    /// Reads a C++ `std::string` (`libc++` short/long string layout on macOS) passed as `const std::string&`.
    private static func readCppStdString(_ ptr: UnsafeRawPointer) -> String {
        let tag = Int8(bitPattern: ptr.load(fromByteOffset: 23, as: UInt8.self))
        if tag < 0 {
            let cPtr = ptr.load(fromByteOffset: 0, as: UnsafePointer<CChar>.self)
            return String(cString: cPtr)
        } else {
            let cPtr = ptr.assumingMemoryBound(to: CChar.self)
            return String(cString: cPtr)
        }
    }

    /// C++ `SketchUpPluginProgressCallback` bridge whose first word is a vtable pointer matching `DWGImporter`'s ABI:
    /// `[0]` `HasBeenCancelled()`, `[1]` `SetPercentDone(double)`, `[2]` `SetStepSize(double)`, `[3]` `Step()`, `[4]` `SetProgressMessage(const std::string&)`.
    private final class ImporterProgressContext: @unchecked Sendable {
        let importerBuf: UnsafeMutableRawPointer
        let progress: (@Sendable (SKPReader.Progress) -> Void)?
        let isCancelled: () -> Bool
        var currentPhase: String = L("Lecture du fichier AutoCAD…", "Reading AutoCAD file…")
        var currentItem: String? = nil
        var lastFraction: Double = 0.08
        var lastEmitTime: CFAbsoluteTime = 0

        init(
            importerBuf: UnsafeMutableRawPointer,
            progress: (@Sendable (SKPReader.Progress) -> Void)?,
            isCancelled: @escaping () -> Bool
        ) {
            self.importerBuf = importerBuf
            self.progress = progress
            self.isCancelled = isCancelled
        }

        func readLiveStats() -> (layers: Int, blocks: Int, edges: Int, faces: Int) {
            let layers = Int(max(0, importerBuf.load(fromByteOffset: 0x2a4, as: Int32.self)))
            let blocks = Int(max(0, importerBuf.load(fromByteOffset: 0x2ac, as: Int32.self)))
            // Arcs (+0x2b0), Circles (+0x2b4), Ellipses (+0x2b8), Lines (+0x2c0), Points (+0x2c4), 2D Polylines (+0x2c8), 3D Polylines (+0x2cc)
            let edgeEntities =
                max(0, importerBuf.load(fromByteOffset: 0x2b0, as: Int32.self)) +
                max(0, importerBuf.load(fromByteOffset: 0x2b4, as: Int32.self)) +
                max(0, importerBuf.load(fromByteOffset: 0x2b8, as: Int32.self)) +
                max(0, importerBuf.load(fromByteOffset: 0x2c0, as: Int32.self)) +
                max(0, importerBuf.load(fromByteOffset: 0x2c4, as: Int32.self)) +
                max(0, importerBuf.load(fromByteOffset: 0x2c8, as: Int32.self)) +
                max(0, importerBuf.load(fromByteOffset: 0x2cc, as: Int32.self))
            // 3D Poly-Meshes (+0x2d0), SubD Meshes (+0x2d4), Poly-Face Meshes (+0x2d8), 3D Faces (+0x2dc)
            let faceEntities =
                max(0, importerBuf.load(fromByteOffset: 0x2d0, as: Int32.self)) +
                max(0, importerBuf.load(fromByteOffset: 0x2d4, as: Int32.self)) +
                max(0, importerBuf.load(fromByteOffset: 0x2d8, as: Int32.self)) +
                max(0, importerBuf.load(fromByteOffset: 0x2dc, as: Int32.self))
            return (layers, blocks, Int(edgeEntities), Int(faceEntities))
        }

        func emit(force: Bool = false) {
            guard let progress else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard force || (now - lastEmitTime) >= 0.025 else { return }
            lastEmitTime = now
            let stats = readLiveStats()
            progress(SKPReader.Progress(
                phase: currentPhase,
                faces: stats.faces,
                fraction: lastFraction,
                edges: stats.edges,
                blocks: stats.blocks,
                layers: stats.layers,
                currentItem: currentItem
            ))
        }

        nonisolated(unsafe) static let vtable: UnsafePointer<UnsafeRawPointer> = {
            typealias HasBeenCancelledFn = @convention(c) (UnsafeMutableRawPointer) -> Bool
            typealias SetPercentDoneFn = @convention(c) (UnsafeMutableRawPointer, Double) -> Void
            typealias SetStepSizeFn = @convention(c) (UnsafeMutableRawPointer, Double) -> Void
            typealias StepFn = @convention(c) (UnsafeMutableRawPointer) -> Void
            typealias SetProgressMessageFn = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void

            let fnCancel: HasBeenCancelledFn = { thisPtr in
                let ctxPtr = thisPtr.load(fromByteOffset: 8, as: UnsafeMutableRawPointer.self)
                let ctx = Unmanaged<ImporterProgressContext>.fromOpaque(ctxPtr).takeUnretainedValue()
                return ctx.isCancelled()
            }
            let fnPercent: SetPercentDoneFn = { thisPtr, pct in
                let ctxPtr = thisPtr.load(fromByteOffset: 8, as: UnsafeMutableRawPointer.self)
                let ctx = Unmanaged<ImporterProgressContext>.fromOpaque(ctxPtr).takeUnretainedValue()
                guard ctx.progress != nil else { return }
                let clamped = min(max(pct / 100.0, 0.0), 1.0)
                ctx.lastFraction = 0.10 + clamped * 0.52
                ctx.emit()
            }
            let fnStepSize: SetStepSizeFn = { _, _ in }
            let fnStep: StepFn = { _ in }
            let fnMessage: SetProgressMessageFn = { thisPtr, strPtr in
                let ctxPtr = thisPtr.load(fromByteOffset: 8, as: UnsafeMutableRawPointer.self)
                let ctx = Unmanaged<ImporterProgressContext>.fromOpaque(ctxPtr).takeUnretainedValue()
                guard ctx.progress != nil else { return }
                let now = CFAbsoluteTimeGetCurrent()
                guard (now - ctx.lastEmitTime) >= 0.025 else { return }
                let raw = CADReader.readCppStdString(strPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return }
                if raw.hasPrefix("Importing Layers") {
                    ctx.currentPhase = L("Lecture des calques AutoCAD…", "Reading AutoCAD layers…")
                    ctx.currentItem = nil
                } else if raw.hasPrefix("Importing Entities") {
                    ctx.currentPhase = L("Lecture des entités du plan…", "Reading plan entities…")
                } else if raw.hasPrefix("Importing Block") {
                    var blockName = String(raw.dropFirst("Importing Block".count)).trimmingCharacters(in: .whitespaces)
                    if blockName.hasSuffix("...") {
                        blockName = String(blockName.dropLast(3)).trimmingCharacters(in: .whitespaces)
                    }
                    ctx.currentPhase = L("Importation des blocs AutoCAD…", "Importing AutoCAD blocks…")
                    if !blockName.isEmpty, !blockName.hasPrefix("*") {
                        ctx.currentItem = L("Bloc : \(blockName)", "Block: \(blockName)")
                    }
                }
                ctx.emit(force: true)
            }

            let table = UnsafeMutablePointer<UnsafeRawPointer>.allocate(capacity: 5)
            table[0] = unsafeBitCast(fnCancel, to: UnsafeRawPointer.self)
            table[1] = unsafeBitCast(fnPercent, to: UnsafeRawPointer.self)
            table[2] = unsafeBitCast(fnStepSize, to: UnsafeRawPointer.self)
            table[3] = unsafeBitCast(fnStep, to: UnsafeRawPointer.self)
            table[4] = unsafeBitCast(fnMessage, to: UnsafeRawPointer.self)
            return UnsafePointer(table)
        }()
    }

    private final class LoadedPlugin: @unchecked Sendable {
        typealias Ctor = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias Dtor = @convention(c) (UnsafeMutableRawPointer) -> Void
        typealias OpenFile = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Bool
        typealias ReadAndProcess = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer?) -> Bool

        let ctor: Ctor
        let dtor: Dtor
        let openFile: OpenFile
        let readAndProcess: ReadAndProcess

        init(location: PluginLocation) throws {
            Self.preloadFrameworks(at: location.frameworksDir.path)
            guard let handle = dlopen(location.binaryURL.path, RTLD_LAZY | RTLD_LOCAL) else {
                throw SKPError.api(function: "dlopen(DWGImporter): " + String(cString: dlerror()), code: -1)
            }
            guard let pCtor = dlsym(handle, "_ZN8sketchup3dwg11CDDImporterC1Ev"),
                  let pDtor = dlsym(handle, "_ZN8sketchup3dwg11CDDImporterD1Ev"),
                  let pOpen = dlsym(handle, "_ZN8sketchup3dwg11CDDImporter8OpenFileERKNSt3__112basic_stringIwNS2_11char_traitsIwEENS2_9allocatorIwEEEE"),
                  let pRead = dlsym(handle, "_ZN8sketchup3dwg11CDDImporter14ReadAndProcessEP30SketchUpPluginProgressCallback")
            else {
                throw SKPError.api(function: "dlsym(CDDImporter)", code: -1)
            }
            self.ctor = unsafeBitCast(pCtor, to: Ctor.self)
            self.dtor = unsafeBitCast(pDtor, to: Dtor.self)
            self.openFile = unsafeBitCast(pOpen, to: OpenFile.self)
            self.readAndProcess = unsafeBitCast(pRead, to: ReadAndProcess.self)
        }

        private static func preloadFrameworks(at dir: String) {
            // Load the single canonical SketchUpAPI instance first so DWGImporter binds to @rpath/SketchUpAPI
            // and its libCommon*.dylib without loading a second copy into the process.
            if (try? SketchUpAPI.functions()) == nil {
                SketchUpAPI.preloadSiblings(dir)
            }
            let orderedLibs = [
                "liblibcrypto.dylib",
                "libTD_Alloc.dylib",
                "libTD_Root.dylib",
                "libTD_Ge.dylib",
                "libTD_SpatialIndex.dylib",
                "libTD_Gi.dylib",
                "libTD_Gs.dylib",
                "libTD_DbRoot.dylib",
                "libTD_Br.dylib",
                "libTD_BrepBuilder.dylib",
                "libTD_AcisBuilder.dylib",
                "libTD_BrepBuilderFiller.dylib",
                "libTD_BrepRenderer.dylib",
                "libOdBrepModeler.dylib",
                "libTD_DbCore.dylib",
                "TD_DbEntities.tx",
                "ISM.tx",
                "SCENEOE.tx",
                "ACCAMERA.tx",
                "AcMPolygonObj15.tx",
                "ATEXT.tx",
                "RText.tx",
                "WipeOut.tx",
                "TD_DbIO.tx",
                "libTD_Db.dylib",
                "RecomputeDimBlock.tx",
                "ModelerGeometry.tx",
                "RasterProcessor.tx",
                "TD_DynBlocks.tx",
                "DbCryptModule.tx",
            ]
            for name in orderedLibs {
                let full = dir + "/" + name
                if FileManager.default.fileExists(atPath: full) {
                    _ = dlopen(full, RTLD_LAZY | RTLD_GLOBAL)
                }
            }
        }

        /// Imports a `.dwg`/`.dxf` file directly into an in-memory `SKPModel` in a single pass,
        /// skipping `SUModelMergeCoplanarFaces`, `SUModelOrientFacesConsistently`, and disk `.skp` serialization.
        func importInMemory(
            url: URL,
            fileInfo: SKPFileInfo,
            progress: (@Sendable (SKPReader.Progress) -> Void)?,
            isCancelled: @Sendable () -> Bool
        ) throws -> (model: SKPModel, insunits: Int32) {
            let f = try SketchUpAPI.functions()
            SKPReader.lock.lock()
            defer { SKPReader.lock.unlock() }
            f.SUInitialize()

            let importerBuf = UnsafeMutableRawPointer.allocate(byteCount: 2048, alignment: 16)
            importerBuf.initializeMemory(as: UInt8.self, repeating: 0, count: 2048)
            defer { importerBuf.deallocate() }

            ctor(importerBuf)
            defer { dtor(importerBuf) }

            // Configure CDDImporter fields directly:
            // +0x378: import_units = 7 (Meters -> 1 drawing unit = 39.37007874" = 1.0 m in SUModelRef so SketchUp's
            //         0.001" merge tolerance never collapses millimeter/centimeter details)
            // +0x288: m_bInitialized = 1
            // +0x3f9: orient_faces_consistently = 0 (skip expensive topological face orientation pass)
            // +0x3fd: import_materials = 1 (preserve AutoCAD ACI / TrueColor layer materials)
            // +0x3fa: 0
            // +0x3fb: preserve_drawing_origin = 0
            importerBuf.storeBytes(of: Int32(7), toByteOffset: 0x378, as: Int32.self)
            importerBuf.storeBytes(of: UInt8(1), toByteOffset: 0x288, as: UInt8.self)
            importerBuf.storeBytes(of: UInt8(0), toByteOffset: 0x3f9, as: UInt8.self)
            importerBuf.storeBytes(of: UInt8(1), toByteOffset: 0x3fd, as: UInt8.self)
            importerBuf.storeBytes(of: UInt8(0), toByteOffset: 0x3fa, as: UInt8.self)
            importerBuf.storeBytes(of: UInt8(0), toByteOffset: 0x3fb, as: UInt8.self)

            var utf32 = url.path.unicodeScalars.map { UInt32($0.value) }
            utf32.append(0)
            let opened = utf32.withUnsafeBufferPointer { buf -> Bool in
                let len = UInt64(buf.count - 1)
                var wStr = StdWStringView(data: buf.baseAddress!, size: len, capacityAndFlag: (len + 1) | (1 << 63))
                return withUnsafePointer(to: &wStr) { pWStr in
                    openFile(importerBuf, pWStr)
                }
            }
            guard opened else { throw SKPError.unreadable(url) }
            if isCancelled() { throw SKPError.cancelled }

            // Read $INSUNITS directly from OdDbDatabase* at [importerBuf + 0x3d8] (vtable + 0x568: getINSUNITS())
            var insunits: Int32 = 0
            if let dbPtr = importerBuf.load(fromByteOffset: 0x3d8, as: UnsafeMutableRawPointer?.self) {
                let vtable = dbPtr.load(as: UnsafeRawPointer.self)
                typealias GetInsunitsFn = @convention(c) (UnsafeMutableRawPointer) -> Int32
                let fnPtr = vtable.load(fromByteOffset: 0x568, as: UnsafeRawPointer.self)
                let getInsunits = unsafeBitCast(fnPtr, to: GetInsunitsFn.self)
                insunits = getInsunits(dbPtr)
            }

            // Create the destination SUModelRef at [importerBuf + 0x290]
            var modelRef: Ref = nil
            guard f.SUModelCreate(&modelRef) == 0, let validModelRef = modelRef else {
                throw SKPError.unreadable(url)
            }
            importerBuf.storeBytes(of: validModelRef, toByteOffset: 0x290, as: UnsafeMutableRawPointer.self)
            defer {
                var refToRelease: Ref = importerBuf.load(fromByteOffset: 0x290, as: UnsafeMutableRawPointer?.self)
                if refToRelease != nil {
                    _ = f.SUModelRelease(&refToRelease)
                    importerBuf.storeBytes(of: nil as UnsafeMutableRawPointer?, toByteOffset: 0x290, as: UnsafeMutableRawPointer?.self)
                }
            }

            // Run ReadAndProcess with live progress & cancellation callback
            let processed: Bool = withoutActuallyEscaping(isCancelled) { escapableCancel in
                let ctx = ImporterProgressContext(importerBuf: importerBuf, progress: progress, isCancelled: escapableCancel)
                let callbackObj = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 8)
                defer { callbackObj.deallocate() }
                callbackObj.storeBytes(of: UnsafeRawPointer(ImporterProgressContext.vtable), toByteOffset: 0, as: UnsafeRawPointer.self)
                callbackObj.storeBytes(of: Unmanaged.passUnretained(ctx).toOpaque(), toByteOffset: 8, as: UnsafeMutableRawPointer.self)
                return withExtendedLifetime(ctx) {
                    readAndProcess(importerBuf, callbackObj)
                }
            }

            // Release OdDbDatabase* early now that ReadAndProcess has finished
            if let dbPtr = importerBuf.load(fromByteOffset: 0x3d8, as: UnsafeMutableRawPointer?.self) {
                let vtable = dbPtr.load(as: UnsafeRawPointer.self)
                typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer) -> Void
                let fnPtr = vtable.load(fromByteOffset: 0x30, as: UnsafeRawPointer.self)
                unsafeBitCast(fnPtr, to: ReleaseFn.self)(dbPtr)
                importerBuf.storeBytes(of: nil as UnsafeMutableRawPointer?, toByteOffset: 0x3d8, as: UnsafeMutableRawPointer?.self)
            }

            if isCancelled() { throw SKPError.cancelled }
            guard processed else { throw SKPError.unreadable(url) }

            let liveModelRef: Ref = importerBuf.load(fromByteOffset: 0x290, as: UnsafeMutableRawPointer?.self)
            let model = try SKPReader.readModelRef(
                liveModelRef,
                f: f,
                fileInfo: fileInfo,
                checkCancelBeforeConvert: false,
                progress: { p in
                    let mapped = p.fraction.map { 0.62 + $0 * 0.28 } ?? 0.75
                    progress?(SKPReader.Progress(
                        phase: p.phase,
                        faces: p.faces,
                        fraction: mapped,
                        edges: p.edges,
                        blocks: p.blocks,
                        layers: p.layers,
                        currentItem: p.currentItem
                    ))
                },
                isCancelled: isCancelled
            )
            return (model, insunits)
        }
    }

    private static let pluginLock = NSLock()
    nonisolated(unsafe) private static var cachedPlugin: LoadedPlugin?

    private static func getPlugin(_ location: PluginLocation) throws -> LoadedPlugin {
        pluginLock.lock()
        defer { pluginLock.unlock() }
        if let cachedPlugin { return cachedPlugin }
        let loaded = try LoadedPlugin(location: location)
        cachedPlugin = loaded
        return loaded
    }

    /// Meters per drawing unit according to AutoCAD `$INSUNITS` (`OdDb::UnitsValue`), matching `CDDImporter::ReadHeaderInfo`.
    private static func metersPerDrawingUnit(forInsunits insunits: Int32) -> Float {
        switch insunits {
        case 2: return 0.3048        // Feet
        case 3: return 1609.344      // Miles
        case 4: return 0.001         // Millimeters
        case 5: return 0.01          // Centimeters
        case 6: return 1.0           // Meters
        case 7: return 1000.0        // Kilometers
        case 8: return 0.0254e-6     // Microinches
        case 9: return 0.0254e-3     // Mils
        case 10: return 0.9144       // Yards
        default: return 0.0254       // 0 (Unitless) or 1 (Inches) -> 1 inch
        }
    }

    private static func loadViaPlugin(
        url: URL,
        fileInfo: SKPFileInfo,
        plugin location: PluginLocation,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        let plugin = try getPlugin(location)
        var (model, insunits) = try plugin.importInMemory(
            url: url,
            fileInfo: fileInfo,
            progress: progress,
            isCancelled: isCancelled
        )

        // Because `importInMemory` imports with `import_units = 7` (1 drawing unit = 1.0 m),
        // `rawMaxDim` is the drawing's span in raw AutoCAD drawing units.
        let rawMaxDim = max(model.size.x, model.size.y, model.size.z)
        let headerUnitScale = metersPerDrawingUnit(forInsunits: insunits)
        let headerMetricMaxDim = rawMaxDim * headerUnitScale

        if headerMetricMaxDim >= 1.0 {
            if headerUnitScale != 1.0 {
                model = scaleModel(model, by: headerUnitScale)
            }
        } else if rawMaxDim > 350.0 {
            // Drawing has $INSUNITS=0 (Unitless) or $INSUNITS=4 (mm) while authored in centimeters or decimeters
            let scale: Float = rawMaxDim > 3_500.0 ? 0.001 : 0.1
            model = scaleModel(model, by: scale)
        }

        progress?(SKPReader.Progress(
            phase: L("Calibrage des unités…", "Calibrating units…"),
            faces: model.stats.faces,
            fraction: 0.92,
            edges: model.stats.edges,
            blocks: model.stats.definitions,
            layers: model.layers.count
        ))
        return normalizeCADModel(model)
    }

    // MARK: - Coordinate Normalization (Scale & Geodetic Origin Recentering)

    static func normalizeCADModel(_ model: SKPModel) -> SKPModel {
        var result = model
        let maxDim = max(result.size.x, result.size.y, result.size.z)
        if maxDim > 5_000.0 {
            // Drawn in millimeters while $INSUNITS was set to meters (e.g. 67,000 m -> 67.0 m)
            result = scaleModel(result, by: 0.001)
        } else if maxDim > 0 && maxDim < 0.05 {
            result = scaleModel(result, by: 1000.0)
        }

        // Recenter georeferenced (e.g. Lambert-93 / UTM) CAD drawings whose XY center is far from the origin
        // so Float32 GPU vertex buffers keep sub-millimeter precision and the reference grid aligns with the model.
        let xyCenter = SIMD2<Float>(result.center.x, result.center.y)
        let xySpan = max(result.size.x, result.size.y, 1.0)
        if simd_length(xyCenter) > max(200.0, xySpan * 2.0) {
            let shift = -SIMD3<Float>(result.center.x, result.center.y, 0)
            result = translateRoot(result, by: shift)
        }

        // AutoCAD's internal "*Active" VPORT table record is a working editor state, not a curated presentation scene,
        // and often points away from the geometry or into a tight detail crop. Clear it so SimpleSKP frames the full
        // model (.top for 2D plans, .iso for 3D models) on open and on Reset View (Z).
        result.camera = nil
        if result.scenes.count == 1, result.scenes[0].name == "*Active" {
            result.scenes = []
        }

        // In 2D CAD plans, clamp outlier Z elevations on placed instances/vertices that sit far outside the plan's XY span
        // so the bounding sphere used for camera framing fits the plan tightly.
        if result.isPlanar2D, result.size.z > xySpan * 0.25 {
            result = flattenOutlierZIn2DPlan(result, maxAbsZ: xySpan * 0.1)
        }

        return result
    }

    private static func flattenOutlierZIn2DPlan(_ model: SKPModel, maxAbsZ: Float) -> SKPModel {
        func clampZ(_ def: SKPModel.Definition) -> SKPModel.Definition {
            var d = def
            for i in d.meshes.indices {
                for j in d.meshes[i].positions.indices where abs(d.meshes[i].positions[j].z) > maxAbsZ {
                    d.meshes[i].positions[j].z = 0
                }
            }
            for i in d.edges.indices {
                for j in d.edges[i].positions.indices where abs(d.edges[i].positions[j].z) > maxAbsZ {
                    d.edges[i].positions[j].z = 0
                }
            }
            for i in d.children.indices where abs(d.children[i].transform.columns.3.z) > maxAbsZ {
                d.children[i].transform.columns.3.z = 0
            }
            return d
        }
        let root = clampZ(model.root)
        let defs = model.definitions.map(clampZ)
        let clampedMinZ = max(model.boundsMin.z, -maxAbsZ)
        let clampedMaxZ = min(model.boundsMax.z, maxAbsZ)
        return SKPModel(
            root: root,
            definitions: defs,
            materials: model.materials,
            layers: model.layers,
            scenes: model.scenes,
            camera: model.camera,
            boundsMin: SIMD3(model.boundsMin.x, model.boundsMin.y, min(clampedMinZ, clampedMaxZ)),
            boundsMax: SIMD3(model.boundsMax.x, model.boundsMax.y, max(clampedMinZ, clampedMaxZ)),
            stats: model.stats,
            fileInfo: model.fileInfo,
            loadWarning: model.loadWarning,
            textureDirectory: model.textureDirectory
        )
    }

    static func scaleModel(_ model: SKPModel, by scale: Float) -> SKPModel {
        guard scale != 1.0, scale > 0 else { return model }
        func scaleDef(_ def: SKPModel.Definition) -> SKPModel.Definition {
            var d = def
            for i in d.meshes.indices {
                for j in d.meshes[i].positions.indices {
                    d.meshes[i].positions[j] *= scale
                }
            }
            for i in d.edges.indices {
                for j in d.edges[i].positions.indices {
                    d.edges[i].positions[j] *= scale
                }
            }
            for i in d.children.indices {
                d.children[i].transform.columns.3.x *= scale
                d.children[i].transform.columns.3.y *= scale
                d.children[i].transform.columns.3.z *= scale
            }
            return d
        }
        let scaledRoot = scaleDef(model.root)
        let scaledDefs = model.definitions.map(scaleDef)
        var scaledCamera = model.camera
        if var cam = scaledCamera {
            cam.position *= scale
            cam.target *= scale
            cam.orthoHeight *= scale
            scaledCamera = cam
        }
        return SKPModel(
            root: scaledRoot,
            definitions: scaledDefs,
            materials: model.materials,
            layers: model.layers,
            scenes: model.scenes,
            camera: scaledCamera,
            boundsMin: model.boundsMin * scale,
            boundsMax: model.boundsMax * scale,
            stats: model.stats,
            fileInfo: model.fileInfo,
            loadWarning: model.loadWarning,
            textureDirectory: model.textureDirectory
        )
    }

    static func translateRoot(_ model: SKPModel, by delta: SIMD3<Float>) -> SKPModel {
        var root = model.root
        for i in root.meshes.indices {
            for j in root.meshes[i].positions.indices {
                root.meshes[i].positions[j] += delta
            }
        }
        for i in root.edges.indices {
            for j in root.edges[i].positions.indices {
                root.edges[i].positions[j] += delta
            }
        }
        for i in root.children.indices {
            root.children[i].transform.columns.3.x += delta.x
            root.children[i].transform.columns.3.y += delta.y
            root.children[i].transform.columns.3.z += delta.z
        }
        var cam = model.camera
        if var c = cam {
            c.position += delta
            c.target += delta
            cam = c
        }
        return SKPModel(
            root: root,
            definitions: model.definitions,
            materials: model.materials,
            layers: model.layers,
            scenes: model.scenes,
            camera: cam,
            boundsMin: model.boundsMin + delta,
            boundsMax: model.boundsMax + delta,
            stats: model.stats,
            fileInfo: model.fileInfo,
            loadWarning: model.loadWarning,
            textureDirectory: model.textureDirectory
        )
    }

    // MARK: - AutoCAD Color Index (ACI 1…255) & TrueColor Lookup

    /// Converts an AutoCAD 24-bit TrueColor integer (DXF group code `420`) to sRGB `0…1`.
    public static func trueColor(from code420: Int) -> SIMD4<Float> {
        let r = Float((code420 >> 16) & 0xFF) / 255.0
        let g = Float((code420 >> 8) & 0xFF) / 255.0
        let b = Float(code420 & 0xFF) / 255.0
        return SIMD4<Float>(r, g, b, 1.0)
    }

    /// Converts an AutoCAD Color Index (`1…255`, DXF group code `62`) to sRGB `0…1`.
    /// Negative indices in DXF LAYER records indicate a hidden layer Whose color is `abs(index)`.
    public static func aciColor(for rawIndex: Int) -> SIMD4<Float>? {
        let idx = abs(rawIndex)
        guard idx >= 1 && idx <= 255 else { return nil }
        switch idx {
        case 1: return SIMD4(1.00, 0.00, 0.00, 1.0) // Red
        case 2: return SIMD4(1.00, 1.00, 0.00, 1.0) // Yellow
        case 3: return SIMD4(0.00, 1.00, 0.00, 1.0) // Green
        case 4: return SIMD4(0.00, 1.00, 1.00, 1.0) // Cyan
        case 5: return SIMD4(0.00, 0.00, 1.00, 1.0) // Blue
        case 6: return SIMD4(1.00, 0.00, 1.00, 1.0) // Magenta
        case 7: return SIMD4(1.00, 1.00, 1.00, 1.0) // White / Black (adaptive)
        case 8: return SIMD4(0.50, 0.50, 0.50, 1.0) // Dark grey
        case 9: return SIMD4(0.75, 0.75, 0.75, 1.0) // Light grey
        case 250...255:
            // Standard 6-step AutoCAD greyscale ramp
            let t = Float(idx - 250) / 5.0
            let v = 0.20 + t * 0.76
            return SIMD4(v, v, v, 1.0)
        default:
            // Standard AutoCAD 10…249 24-hue × 10-shade palette
            let hueStep = (idx - 10) / 10 // 0…23 (15° increments starting at Red = 0°)
            let shade = (idx - 10) % 10   // 0,2,4,6,8 = full saturation brightness steps; 1,3,5,7,9 = pastel tint steps
            let hueDeg = Float(hueStep) * 15.0
            let brightnessFactors: [Float] = [1.00, 1.00, 0.80, 0.80, 0.60, 0.60, 0.50, 0.50, 0.30, 0.30]
            let saturation: Float = (shade % 2 == 0) ? 1.0 : 0.50
            let value = brightnessFactors[shade]
            let c = value * saturation
            let x = c * (1.0 - abs((hueDeg / 60.0).truncatingRemainder(dividingBy: 2.0) - 1.0))
            let m = value - c
            let (r1, g1, b1): (Float, Float, Float)
            switch Int(hueDeg / 60.0) % 6 {
            case 0: (r1, g1, b1) = (c, x, 0)
            case 1: (r1, g1, b1) = (x, c, 0)
            case 2: (r1, g1, b1) = (0, c, x)
            case 3: (r1, g1, b1) = (0, x, c)
            case 4: (r1, g1, b1) = (x, 0, c)
            default: (r1, g1, b1) = (c, 0, x)
            }
            return SIMD4(r1 + m, g1 + m, b1 + m, 1.0)
        }
    }
}

// MARK: - Native Swift ASCII DXF Parser (Fallback & Standalone Support)

enum DXFNativeParser {
    static func parse(
        url: URL,
        fileInfo: SKPFileInfo,
        progress: (@Sendable (SKPReader.Progress) -> Void)?,
        isCancelled: @Sendable () -> Bool
    ) throws -> SKPModel {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SKPError.unreadable(url)
        }

        var lines: [Substring] = []
        lines.reserveCapacity(min(content.count / 6, 2_000_000))
        content.enumerateLines { line, _ in
            lines.append( Substring(line.trimmingCharacters(in: .whitespacesAndNewlines)) )
        }

        var pairIndex = 0
        let totalPairs = lines.count / 2
        func nextPair() -> (Int, String)? {
            while pairIndex * 2 + 1 < lines.count {
                let codeStr = lines[pairIndex * 2]
                let valStr = String(lines[pairIndex * 2 + 1])
                pairIndex += 1
                if let code = Int(codeStr) {
                    return (code, valStr)
                }
            }
            return nil
        }

        var unitScale: Float = 1.0 // default 1 unit = 1 m
        var layers: [SKPModel.Layer] = [SKPModel.Layer(name: "0", isVisible: true, color: CADReader.aciColor(for: 7))]
        var layerIndexByName: [String: Int] = ["0": 0]

        func ensureLayer(_ name: String, visible: Bool = true, color: SIMD4<Float>? = nil) -> Int {
            let clean = name.isEmpty ? "0" : name
            if let idx = layerIndexByName[clean] {
                if let color, layers[idx].color == nil {
                    layers[idx].color = color
                }
                return idx
            }
            let idx = layers.count
            layers.append(SKPModel.Layer(name: clean, isVisible: visible, color: color))
            layerIndexByName[clean] = idx
            return idx
        }

        struct RawGeometry {
            var edgesByLayer: [Int: [SIMD3<Float>]] = [:]
            var facesByLayer: [Int: (positions: [SIMD3<Float>], normals: [SIMD3<Float>], indices: [UInt32])] = [:]
            var pointsByLayer: [Int: [SIMD3<Float>]] = [:]
            var inserts: [(blockName: String, layer: Int, position: SIMD3<Float>, scale: SIMD3<Float>, rotationDeg: Float)] = []

            mutating func addSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, layer: Int) {
                guard simd_distance_squared(a, b) > 1e-12 else { return }
                edgesByLayer[layer, default: []].append(a)
                edgesByLayer[layer, default: []].append(b)
            }

            mutating func addQuadOrTri(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>?, layer: Int) {
                let e1 = p1 - p0, e2 = p2 - p0
                let cross = simd_cross(e1, e2)
                let len = simd_length(cross)
                let n = len > 1e-8 ? cross / len : SIMD3<Float>(0, 0, 1)
                var batch = facesByLayer[layer] ?? ([], [], [])
                let base = UInt32(batch.positions.count)
                if let p3, simd_distance_squared(p2, p3) > 1e-10 {
                    batch.positions.append(contentsOf: [p0, p1, p2, p3])
                    batch.normals.append(contentsOf: [n, n, n, n])
                    batch.indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
                } else {
                    batch.positions.append(contentsOf: [p0, p1, p2])
                    batch.normals.append(contentsOf: [n, n, n])
                    batch.indices.append(contentsOf: [base, base + 1, base + 2])
                }
                facesByLayer[layer] = batch
            }
        }

        var rootGeo = RawGeometry()
        var blocks: [String: RawGeometry] = [:]

        // Helper to parse an entity stream until ENDSEC or ENDBLK
        var pendingPair: (Int, String)? = nil
        func readPair() -> (Int, String)? {
            if let p = pendingPair { pendingPair = nil; return p }
            return nextPair()
        }

        func parseEntities(into geo: inout RawGeometry, stopAtEndBlk: Bool) throws {
            while let (code, val) = readPair() {
                if pairIndex % 25_000 == 0 {
                    if isCancelled() { throw SKPError.cancelled }
                    let frac = totalPairs > 0 ? min(0.86, 0.15 + 0.70 * Double(pairIndex) / Double(totalPairs)) : 0.5
                    let edgeCount = geo.edgesByLayer.values.reduce(0) { $0 + $1.count / 2 }
                    progress?(SKPReader.Progress(
                        phase: L("Lecture des entités DXF…", "Reading DXF entities…"),
                        faces: 0,
                        fraction: frac,
                        edges: edgeCount,
                        blocks: blocks.count,
                        layers: layers.count
                    ))
                }
                guard code == 0 else { continue }
                let entity = val.uppercased()
                if entity == "ENDSEC" || (stopAtEndBlk && entity == "ENDBLK") {
                    return
                }

                switch entity {
                case "LINE":
                    var lyr = "0"
                    var entColor: SIMD4<Float>? = nil
                    var x1: Float = 0, y1: Float = 0, z1: Float = 0
                    var x2: Float = 0, y2: Float = 0, z2: Float = 0
                    while let (c, v) = readPair() {
                        if c == 0 { pendingPair = (c, v); break }
                        switch c {
                        case 8: lyr = v
                        case 62: if let aci = Int(v), entColor == nil { entColor = CADReader.aciColor(for: aci) }
                        case 420: if let tc = Int(v) { entColor = CADReader.trueColor(from: tc) }
                        case 10: x1 = Float(v) ?? 0
                        case 20: y1 = Float(v) ?? 0
                        case 30: z1 = Float(v) ?? 0
                        case 11: x2 = Float(v) ?? 0
                        case 21: y2 = Float(v) ?? 0
                        case 31: z2 = Float(v) ?? 0
                        default: break
                        }
                    }
                    geo.addSegment(SIMD3(x1, y1, z1), SIMD3(x2, y2, z2), layer: ensureLayer(lyr, color: entColor))

                case "LWPOLYLINE":
                    var lyr = "0"
                    var entColor: SIMD4<Float>? = nil
                    var flags = 0
                    var elevation: Float = 0
                    var pts: [SIMD2<Float>] = []
                    var curX: Float? = nil
                    while let (c, v) = readPair() {
                        if c == 0 { pendingPair = (c, v); break }
                        switch c {
                        case 8: lyr = v
                        case 62: if let aci = Int(v), entColor == nil { entColor = CADReader.aciColor(for: aci) }
                        case 420: if let tc = Int(v) { entColor = CADReader.trueColor(from: tc) }
                        case 38: elevation = Float(v) ?? 0
                        case 70: flags = Int(v) ?? 0
                        case 10:
                            curX = Float(v) ?? 0
                        case 20:
                            if let x = curX {
                                pts.append(SIMD2(x, Float(v) ?? 0))
                                curX = nil
                            }
                        default: break
                        }
                    }
                    let lIdx = ensureLayer(lyr, color: entColor)
                    if pts.count >= 2 {
                        for i in 0..<(pts.count - 1) {
                            geo.addSegment(SIMD3(pts[i].x, pts[i].y, elevation), SIMD3(pts[i + 1].x, pts[i + 1].y, elevation), layer: lIdx)
                        }
                        if (flags & 1) != 0, pts.count >= 3 {
                            geo.addSegment(SIMD3(pts.last!.x, pts.last!.y, elevation), SIMD3(pts[0].x, pts[0].y, elevation), layer: lIdx)
                        }
                    }

                case "POLYLINE":
                    var lyr = "0"
                    var flags = 0
                    while let (c, v) = readPair() {
                        if c == 0 { pendingPair = (c, v); break }
                        if c == 8 { lyr = v }
                        else if c == 70 { flags = Int(v) ?? 0 }
                    }
                    var pts: [SIMD3<Float>] = []
                    var polyfaceIndices: [[Int]] = []
                    while let (c, v) = readPair() {
                        guard c == 0 else { continue }
                        let sub = v.uppercased()
                        if sub == "SEQEND" { break }
                        if sub == "VERTEX" {
                            var vx: Float = 0, vy: Float = 0, vz: Float = 0
                            var vFlags = 0
                            var i1 = 0, i2 = 0, i3 = 0, i4 = 0
                            while let (vc, vv) = readPair() {
                                if vc == 0 { pendingPair = (vc, vv); break }
                                switch vc {
                                case 10: vx = Float(vv) ?? 0
                                case 20: vy = Float(vv) ?? 0
                                case 30: vz = Float(vv) ?? 0
                                case 70: vFlags = Int(vv) ?? 0
                                case 71: i1 = abs(Int(vv) ?? 0)
                                case 72: i2 = abs(Int(vv) ?? 0)
                                case 73: i3 = abs(Int(vv) ?? 0)
                                case 74: i4 = abs(Int(vv) ?? 0)
                                default: break
                                }
                            }
                            if (vFlags & 128) != 0 && (vFlags & 64) == 0 && i1 > 0 && i2 > 0 && i3 > 0 {
                                polyfaceIndices.append(i4 > 0 ? [i1, i2, i3, i4] : [i1, i2, i3])
                            } else {
                                pts.append(SIMD3(vx, vy, vz))
                            }
                        } else {
                            pendingPair = (c, v)
                            break
                        }
                    }
                    let lIdx = ensureLayer(lyr)
                    if !polyfaceIndices.isEmpty {
                        for face in polyfaceIndices {
                            guard face.allSatisfy({ $0 >= 1 && $0 <= pts.count }) else { continue }
                            let p0 = pts[face[0] - 1], p1 = pts[face[1] - 1], p2 = pts[face[2] - 1]
                            let p3 = face.count >= 4 ? pts[face[3] - 1] : nil
                            geo.addQuadOrTri(p0, p1, p2, p3, layer: lIdx)
                            geo.addSegment(p0, p1, layer: lIdx)
                            geo.addSegment(p1, p2, layer: lIdx)
                            if let p3 {
                                geo.addSegment(p2, p3, layer: lIdx)
                                geo.addSegment(p3, p0, layer: lIdx)
                            } else {
                                geo.addSegment(p2, p0, layer: lIdx)
                            }
                        }
                    } else if pts.count >= 2 {
                        for i in 0..<(pts.count - 1) {
                            geo.addSegment(pts[i], pts[i + 1], layer: lIdx)
                        }
                        if (flags & 1) != 0, pts.count >= 3 {
                            geo.addSegment(pts.last!, pts[0], layer: lIdx)
                        }
                    }

                case "CIRCLE", "ARC":
                    let isArc = (entity == "ARC")
                    var lyr = "0"
                    var cx: Float = 0, cy: Float = 0, cz: Float = 0, r: Float = 0
                    var startDeg: Float = 0, endDeg: Float = 360
                    while let (c, v) = readPair() {
                        if c == 0 { pendingPair = (c, v); break }
                        switch c {
                        case 8: lyr = v
                        case 10: cx = Float(v) ?? 0
                        case 20: cy = Float(v) ?? 0
                        case 30: cz = Float(v) ?? 0
                        case 40: r = Float(v) ?? 0
                        case 50: startDeg = Float(v) ?? 0
                        case 51: endDeg = Float(v) ?? 360
                        default: break
                        }
                    }
                    if r > 1e-6 {
                        let lIdx = ensureLayer(lyr)
                        let sRad = (isArc ? startDeg : 0) * .pi / 180
                        var eRad = (isArc ? endDeg : 360) * .pi / 180
                        while eRad <= sRad { eRad += 2 * .pi }
                        let segs = max(8, Int(ceil((eRad - sRad) / (.pi / 12))))
                        var prev = SIMD3(cx + r * cos(sRad), cy + r * sin(sRad), cz)
                        for i in 1...segs {
                            let a = sRad + (eRad - sRad) * Float(i) / Float(segs)
                            let cur = SIMD3(cx + r * cos(a), cy + r * sin(a), cz)
                            geo.addSegment(prev, cur, layer: lIdx)
                            prev = cur
                        }
                    }

                case "3DFACE", "SOLID", "TRACE":
                    var lyr = "0"
                    var p0 = SIMD3<Float>.zero, p1 = SIMD3<Float>.zero, p2 = SIMD3<Float>.zero, p3 = SIMD3<Float>.zero
                    var hasP3 = false
                    while let (c, v) = readPair() {
                        if c == 0 { pendingPair = (c, v); break }
                        switch c {
                        case 8: lyr = v
                        case 10: p0.x = Float(v) ?? 0
                        case 20: p0.y = Float(v) ?? 0
                        case 30: p0.z = Float(v) ?? 0
                        case 11: p1.x = Float(v) ?? 0
                        case 21: p1.y = Float(v) ?? 0
                        case 31: p1.z = Float(v) ?? 0
                        case 12: p2.x = Float(v) ?? 0
                        case 22: p2.y = Float(v) ?? 0
                        case 32: p2.z = Float(v) ?? 0
                        case 13: p3.x = Float(v) ?? 0; hasP3 = true
                        case 23: p3.y = Float(v) ?? 0; hasP3 = true
                        case 33: p3.z = Float(v) ?? 0; hasP3 = true
                        default: break
                        }
                    }
                    let lIdx = ensureLayer(lyr)
                    if entity == "SOLID" || entity == "TRACE" {
                        // DXF SOLID orders vertices (0, 1, 3, 2)
                        geo.addQuadOrTri(p0, p1, p3, hasP3 ? p2 : nil, layer: lIdx)
                    } else {
                        geo.addQuadOrTri(p0, p1, p2, hasP3 ? p3 : nil, layer: lIdx)
                    }
                    geo.addSegment(p0, p1, layer: lIdx)
                    geo.addSegment(p1, p2, layer: lIdx)
                    if hasP3 && simd_distance_squared(p2, p3) > 1e-10 {
                        geo.addSegment(p2, p3, layer: lIdx)
                        geo.addSegment(p3, p0, layer: lIdx)
                    } else {
                        geo.addSegment(p2, p0, layer: lIdx)
                    }

                case "POINT":
                    var lyr = "0"
                    var p = SIMD3<Float>.zero
                    while let (c, v) = readPair() {
                        if c == 0 { pendingPair = (c, v); break }
                        switch c {
                        case 8: lyr = v
                        case 10: p.x = Float(v) ?? 0
                        case 20: p.y = Float(v) ?? 0
                        case 30: p.z = Float(v) ?? 0
                        default: break
                        }
                    }
                    geo.pointsByLayer[ensureLayer(lyr), default: []].append(p)

                case "INSERT":
                    var lyr = "0"
                    var blockName = ""
                    var pos = SIMD3<Float>.zero
                    var scale = SIMD3<Float>(repeating: 1)
                    var rot: Float = 0
                    while let (c, v) = readPair() {
                        if c == 0 { pendingPair = (c, v); break }
                        switch c {
                        case 2: blockName = v
                        case 8: lyr = v
                        case 10: pos.x = Float(v) ?? 0
                        case 20: pos.y = Float(v) ?? 0
                        case 30: pos.z = Float(v) ?? 0
                        case 41: scale.x = Float(v) ?? 1
                        case 42: scale.y = Float(v) ?? 1
                        case 43: scale.z = Float(v) ?? 1
                        case 50: rot = Float(v) ?? 0
                        default: break
                        }
                    }
                    if !blockName.isEmpty {
                        geo.inserts.append((blockName, ensureLayer(lyr), pos, scale, rot))
                    }

                default:
                    while let (c, v) = readPair() {
                        if c == 0 { pendingPair = (c, v); break }
                    }
                }
            }
        }

        // Main DXF section loop
        while let (code, val) = readPair() {
            if isCancelled() { throw SKPError.cancelled }
            guard code == 0, val.uppercased() == "SECTION",
                  let (secCode, secNameRaw) = readPair(), secCode == 2 else { continue }
            let secName = secNameRaw.uppercased()

            switch secName {
            case "HEADER":
                while let (c, v) = readPair() {
                    if c == 0 && v.uppercased() == "ENDSEC" { break }
                    if c == 9 && v.uppercased() == "$INSUNITS" {
                        if let (uc, uv) = readPair(), uc == 70, let u = Int(uv) {
                            switch u {
                            case 1: unitScale = 0.0254     // Inches
                            case 2: unitScale = 0.3048     // Feet
                            case 4: unitScale = 0.001      // Millimeters
                            case 5: unitScale = 0.01       // Centimeters
                            case 6: unitScale = 1.0        // Meters
                            case 7: unitScale = 1000.0     // Kilometers
                            default: unitScale = 1.0
                            }
                        }
                    }
                }

            case "TABLES":
                while let (c, v) = readPair() {
                    if c == 0 && v.uppercased() == "ENDSEC" { break }
                    if c == 0 && v.uppercased() == "LAYER" {
                        var name = ""
                        var colorCode = 7
                        var trueColorCode: Int? = nil
                        var flags = 0
                        while let (lc, lv) = readPair() {
                            if lc == 0 { pendingPair = (lc, lv); break }
                            switch lc {
                            case 2: name = lv
                            case 62: colorCode = Int(lv) ?? 7
                            case 420: trueColorCode = Int(lv)
                            case 70: flags = Int(lv) ?? 0
                            default: break
                            }
                        }
                        if !name.isEmpty {
                            let visible = colorCode >= 0 && (flags & 1) == 0
                            let resolvedColor = trueColorCode.map(CADReader.trueColor(from:)) ?? CADReader.aciColor(for: colorCode)
                            let idx = ensureLayer(name, visible: visible, color: resolvedColor)
                            layers[idx].isVisible = visible
                            if let resolvedColor {
                                layers[idx].color = resolvedColor
                            }
                        }
                    }
                }

            case "BLOCKS":
                while let (c, v) = readPair() {
                    if c == 0 && v.uppercased() == "ENDSEC" { break }
                    if c == 0 && v.uppercased() == "BLOCK" {
                        var blockName = ""
                        var basePt = SIMD3<Float>.zero
                        while let (bc, bv) = readPair() {
                            if bc == 0 { pendingPair = (bc, bv); break }
                            switch bc {
                            case 2, 3: if blockName.isEmpty { blockName = bv }
                            case 10: basePt.x = Float(bv) ?? 0
                            case 20: basePt.y = Float(bv) ?? 0
                            case 30: basePt.z = Float(bv) ?? 0
                            default: break
                            }
                        }
                        var bGeo = RawGeometry()
                        try parseEntities(into: &bGeo, stopAtEndBlk: true)
                        if simd_length_squared(basePt) > 1e-10 {
                            for k in bGeo.edgesByLayer.keys {
                                bGeo.edgesByLayer[k] = bGeo.edgesByLayer[k]!.map { $0 - basePt }
                            }
                        }
                        if !blockName.isEmpty {
                            blocks[blockName] = bGeo
                        }
                    }
                }

            case "ENTITIES":
                progress?(SKPReader.Progress(phase: L("Lecture des entités DXF…", "Reading DXF entities…"), faces: 0))
                try parseEntities(into: &rootGeo, stopAtEndBlk: false)

            default:
                while let (c, v) = readPair() {
                    if c == 0 && v.uppercased() == "ENDSEC" { break }
                }
            }
            _ = totalPairs
        }

        // Convert point clouds if there are points
        func convertPoints(in geo: inout RawGeometry) {
            guard !geo.pointsByLayer.isEmpty else { return }
            let totalPts = geo.pointsByLayer.values.reduce(0) { $0 + $1.count }
            let strideStep = max(1, totalPts / 60_000)
            let tick: Float = 0.015 / max(unitScale, 1e-4)
            for (lyr, pts) in geo.pointsByLayer {
                var out = geo.edgesByLayer[lyr] ?? []
                out.reserveCapacity(out.count + (pts.count / strideStep + 1) * 2)
                for idx in Swift.stride(from: 0, to: pts.count, by: strideStep) {
                    let p = pts[idx]
                    out.append(p - SIMD3(tick, 0, 0))
                    out.append(p + SIMD3(tick, 0, 0))
                }
                geo.edgesByLayer[lyr] = out
            }
        }
        convertPoints(in: &rootGeo)

        var definitions: [SKPModel.Definition] = []
        var defIndexByName: [String: (index: Int, min: SIMD3<Float>, max: SIMD3<Float>)] = [:]
        var stats = SKPModel.Stats()

        func buildDefinition(name: String, from geo: RawGeometry, depth: Int) -> (SKPModel.Definition, SIMD3<Float>, SIMD3<Float>) {
            var meshes: [SKPModel.Mesh] = []
            var edges: [SKPModel.EdgeSet] = []
            var children: [SKPModel.Instance] = []
            var bMin = SIMD3<Float>(repeating: .infinity)
            var bMax = SIMD3<Float>(repeating: -.infinity)

            for (lyr, batch) in geo.facesByLayer.sorted(by: { $0.key < $1.key }) {
                let scaledPos = batch.positions.map { $0 * unitScale }
                for p in scaledPos { bMin = simd_min(bMin, p); bMax = simd_max(bMax, p) }
                meshes.append(SKPModel.Mesh(material: nil, layer: lyr, positions: scaledPos, normals: batch.normals, uvs: nil, indices: batch.indices))
                let triCount = batch.indices.count / 3
                stats.faces += triCount
                stats.triangles += triCount
            }

            for (lyr, pos) in geo.edgesByLayer.sorted(by: { $0.key < $1.key }) where !pos.isEmpty {
                let scaledPos = pos.map { $0 * unitScale }
                for p in scaledPos { bMin = simd_min(bMin, p); bMax = simd_max(bMax, p) }
                edges.append(SKPModel.EdgeSet(layer: lyr, positions: scaledPos))
                stats.edges += scaledPos.count / 2
            }

            if depth < 16 {
                for ins in geo.inserts {
                    let cached: (index: Int, min: SIMD3<Float>, max: SIMD3<Float>)
                    if let hit = defIndexByName[ins.blockName] {
                        cached = hit
                    } else if var bGeo = blocks[ins.blockName] {
                        convertPoints(in: &bGeo)
                        let (childDef, cMin, cMax) = buildDefinition(name: ins.blockName, from: bGeo, depth: depth + 1)
                        definitions.append(childDef)
                        let entry = (definitions.count - 1, cMin, cMax)
                        defIndexByName[ins.blockName] = entry
                        cached = entry
                    } else {
                        continue
                    }

                    let rad = ins.rotationDeg * .pi / 180
                    let c = cos(rad), s = sin(rad)
                    let col0 = SIMD4<Float>(c * ins.scale.x, s * ins.scale.x, 0, 0)
                    let col1 = SIMD4<Float>(-s * ins.scale.y, c * ins.scale.y, 0, 0)
                    let col2 = SIMD4<Float>(0, 0, ins.scale.z, 0)
                    let col3 = SIMD4<Float>(ins.position.x * unitScale, ins.position.y * unitScale, ins.position.z * unitScale, 1)
                    let m = simd_float4x4(col0, col1, col2, col3)
                    children.append(SKPModel.Instance(definition: cached.index, transform: m, layer: ins.layer, isGroup: false, material: nil, name: ins.blockName))
                    stats.instances += 1

                    if cached.min.x <= cached.max.x {
                        for cornerIdx in 0..<8 {
                            let corner = SIMD3<Float>(
                                (cornerIdx & 1) == 0 ? cached.min.x : cached.max.x,
                                (cornerIdx & 2) == 0 ? cached.min.y : cached.max.y,
                                (cornerIdx & 4) == 0 ? cached.min.z : cached.max.z
                            )
                            let wp = m * SIMD4(corner, 1)
                            let p3 = SIMD3(wp.x, wp.y, wp.z)
                            bMin = simd_min(bMin, p3)
                            bMax = simd_max(bMax, p3)
                        }
                    }
                }
            }

            return (SKPModel.Definition(name: name, meshes: meshes, edges: edges, children: children), bMin, bMax)
        }

        let (rootDef, rMin, rMax) = buildDefinition(name: "", from: rootGeo, depth: 0)
        stats.definitions = definitions.count
        let validBounds = rMin.x <= rMax.x
        return SKPModel(
            root: rootDef,
            definitions: definitions,
            materials: [],
            layers: layers,
            scenes: [],
            camera: nil,
            boundsMin: validBounds ? rMin : .zero,
            boundsMax: validBounds ? rMax : .zero,
            stats: stats,
            fileInfo: fileInfo
        )
    }
}
