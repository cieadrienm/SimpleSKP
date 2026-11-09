import Foundation
import simd

@_silgen_name("_CFKeyedArchiverUIDGetTypeID")
private func CFKeyedArchiverUIDGetTypeID() -> CFTypeID

@_silgen_name("_CFKeyedArchiverUIDGetValue")
private func CFKeyedArchiverUIDGetValue(_ uid: AnyObject) -> UInt32

// MARK: - Open Fixture Library (OFL) Definitions (`/Users/adrien/Library/Millumin/Light-fixtures`)

/// A single DMX channel slot inside an OFL fixture mode.
public struct OFLChannelSlot: Codable, Equatable, Sendable {
    public var name: String
    public var role: DMXChannelRole

    public init(name: String, role: DMXChannelRole) {
        self.name = name
        self.role = role
    }
}

/// A DMX personality / mode of an OFL stage light fixture (e.g. `"15-channel"`, `"6-channel"`, `"ERS"`).
public struct OFLFixtureMode: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var shortName: String?
    public var channels: [OFLChannelSlot]

    public var channelCount: Int { channels.count }

    public init(name: String, shortName: String? = nil, channels: [OFLChannelSlot]) {
        self.name = name
        self.shortName = shortName
        self.channels = channels
    }
}

/// Decoded Open Fixture Library (`.json`) stage lighting fixture from `/Users/adrien/Library/Millumin/Light-fixtures`
/// or `/Applications/Millumin5.app/Contents/Resources/ofl_millumin`.
public struct OFLFixtureDefinition: Identifiable, Codable, Equatable, Sendable {
    /// Canonical Millumin fixture identifier, e.g. `"varytec/hero-wash-300-fc"` or `"millumin/Theatrical"`.
    public var id: String
    public var manufacturer: String
    public var name: String
    public var categories: [String]
    public var modes: [OFLFixtureMode]
    public var lumens: Int?
    public var beamAngleMin: Float?
    public var beamAngleMax: Float?
    /// Physical dimensions `[width, height, depth]` in millimetres from OFL `physical.dimensions`.
    public var dimensionsMM: SIMD3<Float>?
    public var colorTemperatureKelvin: Float?
    public var sourceFilePath: String?

    public init(
        id: String,
        manufacturer: String,
        name: String,
        categories: [String] = [],
        modes: [OFLFixtureMode],
        lumens: Int? = nil,
        beamAngleMin: Float? = nil,
        beamAngleMax: Float? = nil,
        dimensionsMM: SIMD3<Float>? = nil,
        colorTemperatureKelvin: Float? = nil,
        sourceFilePath: String? = nil
    ) {
        self.id = id
        self.manufacturer = manufacturer
        self.name = name
        self.categories = categories
        self.modes = modes
        self.lumens = lumens
        self.beamAngleMin = beamAngleMin
        self.beamAngleMax = beamAngleMax
        self.dimensionsMM = dimensionsMM
        self.colorTemperatureKelvin = colorTemperatureKelvin
        self.sourceFilePath = sourceFilePath
    }

    public var displayName: String {
        if name.lowercased().hasPrefix(manufacturer.lowercased()) {
            return name
        }
        return "\(manufacturer) \(name)"
    }

    /// Finds the best matching `OFLFixtureMode` for a Millumin `modeName`.
    public func mode(named modeName: String) -> OFLFixtureMode? {
        resolveMode(named: modeName)
    }

    public func resolveMode(named modeName: String) -> OFLFixtureMode? {
        let trimmed = modeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if let exact = modes.first(where: {
            $0.name.lowercased() == lower || ($0.shortName?.lowercased() == lower)
        }) {
            return exact
        }
        if let partial = modes.first(where: {
            $0.name.lowercased().contains(lower) || lower.contains($0.name.lowercased())
        }) {
            return partial
        }
        // Match by leading integer channel count (e.g. "15-channel" vs "15ch")
        let digits = trimmed.prefix(while: { $0.isNumber })
        if let count = Int(digits), let byCount = modes.first(where: { $0.channels.count == count }) {
            return byCount
        }
        return modes.first
    }

    /// Converts this OFL fixture definition (and optional mode) into a `ProjectorSpec` for SimpleSKP.
    public func toProjectorSpec(modeName: String? = nil) -> ProjectorSpec {
        let idLower = id.lowercased()
        let modeLower = (modeName ?? "").lowercased()

        // Special case for Millumin built-in Theatrical fixture where mode selects ERS (profile spot) vs PAR (wash)
        if idLower == "millumin/theatrical" || idLower.hasSuffix("/_theatrical") {
            if modeLower == "ers" || modeLower.contains("profile") || modeLower.contains("decoupe") {
                return .milluminTheatricalERS
            }
            return .milluminTheatricalPAR
        }

        // Check if we have a curated spec in ProjectorCatalog with matching ID
        let slugID = idLower.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "_", with: "-")
        if let catalogExact = ProjectorCatalog.stageLightSpecs.first(where: {
            $0.id.lowercased() == slugID || $0.id.lowercased() == idLower
        }) {
            return catalogExact
        }

        // Determine kind (profileSpot vs washPanel)
        let isProfile = name.lowercased().contains("profile")
            || name.lowercased().contains("ikon")
            || name.lowercased().contains("decoupe")
            || modeLower == "ers"
        let kind: ProjectorKind = isProfile ? .profileSpot : .washPanel

        // Convert beam angles in degrees to throw ratios: throwRatio = 1 / (2 * tan(angle / 2))
        func angleToThrowRatio(_ deg: Float) -> Float {
            let clampedDeg = simd_clamp(deg, 2.0, 140.0)
            let rad = clampedDeg * .pi / 180.0
            return 1.0 / (2.0 * tan(rad / 2.0))
        }

        let minDeg = beamAngleMin ?? (isProfile ? 18.0 : 25.0)
        let maxDeg = beamAngleMax ?? (isProfile ? 36.0 : 45.0)
        // Larger beam angle -> smaller throw ratio
        let minTR = min(angleToThrowRatio(maxDeg), angleToThrowRatio(minDeg))
        let maxTR = max(angleToThrowRatio(maxDeg), angleToThrowRatio(minDeg))
        let defaultTR = (minTR + maxTR) * 0.5

        let body: SIMD3<Float>
        if let mm = dimensionsMM {
            body = SIMD3<Float>(
                max(0.12, mm.x / 1000.0),
                max(0.10, mm.z / 1000.0),
                max(0.12, mm.y / 1000.0)
            )
        } else {
            body = isProfile ? SIMD3<Float>(0.26, 0.42, 0.26) : SIMD3<Float>(0.28, 0.22, 0.32)
        }

        let allRoles = modes.flatMap { $0.channels.map(\.role) }
        let hasRGB = allRoles.contains(.red) || allRoles.contains(.green) || allRoles.contains(.blue)
        let cct = colorTemperatureKelvin ?? (hasRGB ? nil : 3200)

        return ProjectorSpec(
            id: slugID,
            manufacturer: manufacturer,
            model: name,
            nativeWidth: 1024,
            nativeHeight: 1024,
            minThrowRatio: minTR,
            maxThrowRatio: max(minTR, maxTR),
            defaultThrowRatio: defaultTR,
            maxLensShiftH: 0.0,
            maxLensShiftV: 0.0,
            lumens: lumens ?? (isProfile ? 2200 : 3500),
            bodySize: body,
            kind: kind,
            colorTemperatureKelvin: cct
        )
    }
}

/// Discovers and parses Open Fixture Library (`.json`) files from:
/// - `/Users/adrien/Library/Millumin/Light-fixtures` (`~/Library/Millumin/Light-fixtures`)
/// - `/Applications/Millumin5.app/Contents/Resources/ofl_millumin`
/// Plus built-in definitions for standard Millumin & cie Adrien M stage fixtures.
public final class OFLFixtureLibrary: @unchecked Sendable {
    public static let shared = OFLFixtureLibrary()

    private let lock = NSLock()
    private var fixturesByID: [String: OFLFixtureDefinition] = [:]
    private var orderedFixtures: [OFLFixtureDefinition] = []
    private var didScanDisk = false

    public init() {
        registerBuiltInFixtures()
    }

    /// Returns all available OFL fixtures (user's `~/Library/Millumin/Light-fixtures` + Millumin built-ins).
    public var allFixtures: [OFLFixtureDefinition] {
        ensureScanned()
        lock.lock()
        defer { lock.unlock() }
        return orderedFixtures
    }

    /// Forces a fresh scan of `~/Library/Millumin/Light-fixtures`.
    public func reload() {
        lock.lock()
        didScanDisk = false
        fixturesByID.removeAll()
        orderedFixtures.removeAll()
        lock.unlock()
        registerBuiltInFixtures()
        ensureScanned()
    }

    /// Resolves a Millumin `fixtureIdentifier` (such as `"varytec/hero-wash-300-fc"`, `"eurolite/led-ml-56-rgbw"`, `"millumin/Theatrical"`).
    public func fixture(for identifier: String) -> OFLFixtureDefinition? {
        ensureScanned()
        let clean = Self.normalizeIdentifier(identifier)
        lock.lock()
        defer { lock.unlock() }
        if let exact = fixturesByID[clean] {
            return exact
        }
        // Try stripping manufacturer prefix duplication (e.g. "varytec/varytec_hero-wash-300-fc" <-> "varytec/hero-wash-300-fc")
        let parts = clean.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            let mfr = parts[0]
            let key = parts[1]
            let strippedKey: String
            if key.hasPrefix(mfr + "_") {
                strippedKey = String(key.dropFirst(mfr.count + 1))
            } else if key.hasPrefix(mfr + "-") {
                strippedKey = String(key.dropFirst(mfr.count + 1))
            } else {
                strippedKey = key
            }
            if let found = fixturesByID["\(mfr)/\(strippedKey)"] {
                return found
            }
            // Also try matching just the fixture key across any manufacturer
            if let bySuffix = orderedFixtures.first(where: {
                let idParts = $0.id.lowercased().split(separator: "/")
                return idParts.last.map(String.init) == strippedKey
            }) {
                return bySuffix
            }
        }
        return nil
    }

    public func fixture(forIdentifier identifier: String) -> OFLFixtureDefinition? {
        fixture(for: identifier)
    }

    private static func normalizeIdentifier(_ id: String) -> String {
        id.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    private func ensureScanned() {
        lock.lock()
        if didScanDisk {
            lock.unlock()
            return
        }
        didScanDisk = true
        lock.unlock()

        var directories: [URL] = []
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        directories.append(homeDir.appendingPathComponent("Library/Millumin/Light-fixtures"))
        let adrienPath = URL(fileURLWithPath: "/Users/adrien/Library/Millumin/Light-fixtures")
        if !directories.contains(adrienPath) {
            directories.append(adrienPath)
        }
        directories.append(URL(fileURLWithPath: "/Applications/Millumin5.app/Contents/Resources/ofl_millumin"))
        directories.append(URL(fileURLWithPath: "/Applications/Millumin4.app/Contents/Resources/ofl_millumin"))

        for dir in directories {
            scanDirectory(dir)
        }
    }

    /// Scans a directory containing `<manufacturer>/<fixture>.json` OFL files.
    public func scanDirectory(_ rootURL: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootURL.path),
              let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "json" else { continue }
            let fileName = fileURL.deletingPathExtension().lastPathComponent
            if fileName == "manufacturers" || fileName.hasPrefix("$") { continue }
            let parentName = fileURL.deletingLastPathComponent().lastPathComponent
            if let def = Self.parseOFLFile(at: fileURL, manufacturerKey: parentName) {
                register(def)
            }
        }
    }

    private func register(_ def: OFLFixtureDefinition) {
        lock.lock()
        defer { lock.unlock() }
        let normKey = Self.normalizeIdentifier(def.id)
        fixturesByID[normKey] = def
        fixturesByID[def.id.lowercased()] = def
        if let idx = orderedFixtures.firstIndex(where: { Self.normalizeIdentifier($0.id) == normKey }) {
            orderedFixtures[idx] = def
        } else {
            orderedFixtures.append(def)
        }
    }

    /// Parses an Open Fixture Library (OFL) `.json` file into an `OFLFixtureDefinition`.
    public static func parseOFLFile(at url: URL, manufacturerKey: String? = nil) -> OFLFixtureDefinition? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        guard let fixtureName = json["name"] as? String,
              let rawModes = json["modes"] as? [[String: Any]],
              let availableChannels = json["availableChannels"] as? [String: Any] else {
            return nil
        }

        let rawFileName = url.deletingPathExtension().lastPathComponent
        let mfrKey = (manufacturerKey ?? url.deletingLastPathComponent().lastPathComponent)
        // Strip leading "<manufacturer>_" if present (e.g. "varytec_hero-wash-300-fc" -> "hero-wash-300-fc")
        let cleanFixtureKey: String
        let lowerFile = rawFileName.lowercased()
        let lowerMfr = mfrKey.lowercased()
        if lowerFile.hasPrefix(lowerMfr + "_") {
            cleanFixtureKey = String(rawFileName.dropFirst(mfrKey.count + 1))
        } else if rawFileName == "_theatrical" {
            cleanFixtureKey = "Theatrical"
        } else {
            cleanFixtureKey = rawFileName
        }

        let canonicalID = "\(mfrKey)/\(cleanFixtureKey)"
        let prettyManufacturer: String
        switch lowerMfr {
        case "varytec": prettyManufacturer = "Varytec"
        case "eurolite": prettyManufacturer = "Eurolite"
        case "stairville": prettyManufacturer = "Stairville"
        case "american-dj": prettyManufacturer = "ADJ"
        case "cameo": prettyManufacturer = "Cameo"
        case "showtec": prettyManufacturer = "Showtec"
        case "millumin": prettyManufacturer = "Millumin"
        default: prettyManufacturer = mfrKey.capitalized
        }

        let categories = (json["categories"] as? [String]) ?? []

        // Parse physical properties
        var lumens: Int?
        var beamMin: Float?
        var beamMax: Float?
        var dimsMM: SIMD3<Float>?
        var cct: Float?

        if let physical = json["physical"] as? [String: Any] {
            if let d = physical["dimensions"] as? [NSNumber], d.count >= 3 {
                dimsMM = SIMD3<Float>(d[0].floatValue, d[1].floatValue, d[2].floatValue)
            }
            if let bulb = physical["bulb"] as? [String: Any] {
                if let lm = (bulb["lumens"] as? NSNumber)?.intValue, lm > 0 {
                    lumens = lm
                }
                if let temp = (bulb["colorTemperature"] as? NSNumber)?.floatValue, temp > 0 {
                    cct = temp
                }
            }
            if let lens = physical["lens"] as? [String: Any],
               let degMinMax = lens["degreesMinMax"] as? [NSNumber],
               degMinMax.count >= 2 {
                beamMin = degMinMax[0].floatValue
                beamMax = degMinMax[1].floatValue
            }
        }

        // Build lookup of fineChannelAliases -> coarse channel key
        var fineAliasKeys = Set<String>()
        for (_, chVal) in availableChannels {
            if let chDict = chVal as? [String: Any],
               let aliases = chDict["fineChannelAliases"] as? [String] {
                for alias in aliases {
                    fineAliasKeys.insert(alias)
                }
            }
        }

        // Helper to classify a channel key from availableChannels
        func classifyChannelKey(_ key: String) -> OFLChannelSlot {
            if fineAliasKeys.contains(key) || key.lowercased().contains("fine") {
                return OFLChannelSlot(name: key, role: .other)
            }
            guard let chDict = availableChannels[key] as? [String: Any] else {
                return OFLChannelSlot(name: key, role: DMXChannelRole.classify(name: key))
            }
            let displayName = (chDict["name"] as? String) ?? key
            if let cap = chDict["capability"] as? [String: Any] {
                let oflType = cap["type"] as? String
                let oflColor = cap["color"] as? String
                return OFLChannelSlot(
                    name: displayName,
                    role: DMXChannelRole.classify(name: displayName, oflType: oflType, oflColor: oflColor)
                )
            }
            if let caps = chDict["capabilities"] as? [[String: Any]], !caps.isEmpty {
                // Check if primary capability is intensity/color/zoom/shutter
                let types = Set(caps.compactMap { $0["type"] as? String })
                if types.count == 1, let singleType = types.first {
                    let singleColor = caps.first?["color"] as? String
                    return OFLChannelSlot(
                        name: displayName,
                        role: DMXChannelRole.classify(name: displayName, oflType: singleType, oflColor: singleColor)
                    )
                }
                return OFLChannelSlot(
                    name: displayName,
                    role: DMXChannelRole.classify(name: displayName)
                )
            }
            return OFLChannelSlot(name: displayName, role: DMXChannelRole.classify(name: displayName))
        }

        var parsedModes: [OFLFixtureMode] = []
        for modeDict in rawModes {
            guard let modeName = modeDict["name"] as? String,
                  let rawChannels = modeDict["channels"] as? [Any] else {
                continue
            }
            let shortName = modeDict["shortName"] as? String
            var slots: [OFLChannelSlot] = []
            for item in rawChannels {
                if let chKey = item as? String {
                    slots.append(classifyChannelKey(chKey))
                } else if let matrixDict = item as? [String: Any],
                          let repeatFor = matrixDict["repeatFor"] as? [String],
                          let templateChannels = matrixDict["channelOrder"] as? [String] {
                    // Matrix / pixel ring expansion (e.g. Varytec Hero Wash 300 FC 26-channel mode)
                    for pixelKey in repeatFor {
                        for tpl in templateChannels {
                            let resolvedKey = tpl.replacingOccurrences(of: "$pixelKey", with: pixelKey)
                            slots.append(classifyChannelKey(resolvedKey))
                        }
                    }
                }
            }
            if !slots.isEmpty {
                parsedModes.append(OFLFixtureMode(name: modeName, shortName: shortName, channels: slots))
            }
        }

        guard !parsedModes.isEmpty else { return nil }

        return OFLFixtureDefinition(
            id: canonicalID,
            manufacturer: prettyManufacturer,
            name: fixtureName,
            categories: categories,
            modes: parsedModes,
            lumens: lumens,
            beamAngleMin: beamMin,
            beamAngleMax: beamMax,
            dimensionsMM: dimsMM,
            colorTemperatureKelvin: cct,
            sourceFilePath: url.path
        )
    }

    private func registerBuiltInFixtures() {
        // 1. Millumin built-in Theatrical (ERS, PAR, Flood)
        register(OFLFixtureDefinition(
            id: "millumin/Theatrical",
            manufacturer: "Millumin",
            name: "Theatrical (ERS / PAR)",
            categories: ["Dimmer"],
            modes: [
                OFLFixtureMode(name: "ERS", channels: [.init(name: "Intensity", role: .dimmer)]),
                OFLFixtureMode(name: "PAR", channels: [.init(name: "Intensity", role: .dimmer)]),
                OFLFixtureMode(name: "Flood", channels: [.init(name: "Intensity", role: .dimmer)]),
            ],
            lumens: 2800,
            beamAngleMin: 19,
            beamAngleMax: 36,
            colorTemperatureKelvin: 3200
        ))

        // 2. Millumin built-in RGB-PAR & RGBW-PAR
        register(OFLFixtureDefinition(
            id: "millumin/RGB-PAR",
            manufacturer: "Millumin",
            name: "RGB PAR",
            categories: ["Color Changer"],
            modes: [
                OFLFixtureMode(name: "8bit", shortName: "8b", channels: [
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                ]),
            ],
            lumens: 3000,
            beamAngleMin: 25,
            beamAngleMax: 45
        ))

        register(OFLFixtureDefinition(
            id: "millumin/RGBW-PAR",
            manufacturer: "Millumin",
            name: "RGBW PAR",
            categories: ["Color Changer"],
            modes: [
                OFLFixtureMode(name: "8bit", shortName: "8b", channels: [
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                    .init(name: "White", role: .white),
                ]),
            ],
            lumens: 3500,
            beamAngleMin: 25,
            beamAngleMax: 45
        ))

        // 3. Varytec Hero Wash 300 FC (fallback if disk JSON not yet scanned)
        register(OFLFixtureDefinition(
            id: "varytec/hero-wash-300-fc",
            manufacturer: "Varytec",
            name: "Hero Wash 300 FC",
            categories: ["Moving Head", "Color Changer"],
            modes: [
                OFLFixtureMode(name: "8-channel", shortName: "8ch", channels: [
                    .init(name: "Pan", role: .pan),
                    .init(name: "Tilt", role: .tilt),
                    .init(name: "Zoom", role: .zoom),
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Shutter / Strobe", role: .strobe),
                    .init(name: "Color Temperature", role: .other),
                    .init(name: "Color Ring Macros", role: .colorMacro),
                    .init(name: "Segment Patterns", role: .other),
                ]),
                OFLFixtureMode(name: "15-channel", shortName: "15ch", channels: [
                    .init(name: "Pan", role: .pan),
                    .init(name: "Tilt", role: .tilt),
                    .init(name: "Pan/Tilt Speed", role: .other),
                    .init(name: "Zoom", role: .zoom),
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Shutter / Strobe", role: .strobe),
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                    .init(name: "White", role: .white),
                    .init(name: "Color Temperature", role: .other),
                    .init(name: "Color Ring Macros", role: .colorMacro),
                    .init(name: "Segment Patterns", role: .other),
                    .init(name: "Segment Pattern Transition", role: .other),
                    .init(name: "Function", role: .other),
                ]),
            ],
            lumens: 6000,
            beamAngleMin: 6,
            beamAngleMax: 50,
            dimensionsMM: SIMD3<Float>(310, 390, 208)
        ))

        // 4. Varytec Hero Wash 340FX RGBW Zoom
        register(OFLFixtureDefinition(
            id: "varytec/hero-wash-340fx-rgbw-zoom",
            manufacturer: "Varytec",
            name: "Hero Wash 340FX RGBW Zoom",
            categories: ["Moving Head", "Color Changer"],
            modes: [
                OFLFixtureMode(name: "7-channel", shortName: "7ch", channels: [
                    .init(name: "Pan", role: .pan),
                    .init(name: "Tilt", role: .tilt),
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Shutter / Strobe", role: .strobe),
                    .init(name: "Zoom", role: .zoom),
                    .init(name: "Color Macros", role: .colorMacro),
                    .init(name: "Color Temperature", role: .other),
                ]),
                OFLFixtureMode(name: "16-channel", shortName: "16ch", channels: [
                    .init(name: "Pan", role: .pan),
                    .init(name: "Pan fine", role: .other),
                    .init(name: "Tilt", role: .tilt),
                    .init(name: "Tilt fine", role: .other),
                    .init(name: "Pan/Tilt Speed", role: .other),
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Shutter / Strobe", role: .strobe),
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                    .init(name: "White", role: .white),
                    .init(name: "Color Temperature", role: .other),
                    .init(name: "Color Macros", role: .colorMacro),
                    .init(name: "Zoom", role: .zoom),
                    .init(name: "Segment Patterns", role: .other),
                    .init(name: "Function", role: .other),
                ]),
            ],
            lumens: 5200,
            beamAngleMin: 4,
            beamAngleMax: 55,
            dimensionsMM: SIMD3<Float>(292, 378, 210)
        ))

        // 5. Eurolite LED ML-56 QCL RGBW
        register(OFLFixtureDefinition(
            id: "eurolite/led-ml-56-rgbw",
            manufacturer: "Eurolite",
            name: "LED ML-56 QCL RGBW",
            categories: ["Color Changer"],
            modes: [
                OFLFixtureMode(name: "4-channel", shortName: "4ch", channels: [
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                    .init(name: "Cool White", role: .coldWhite),
                ]),
                OFLFixtureMode(name: "6-channel", shortName: "6ch", channels: [
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                    .init(name: "Cool White", role: .coldWhite),
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Function", role: .other),
                ]),
            ],
            lumens: 2200,
            beamAngleMin: 18,
            beamAngleMax: 45,
            dimensionsMM: SIMD3<Float>(245, 295, 205)
        ))

        // 6. Stairville LED Flood Panel 150
        register(OFLFixtureDefinition(
            id: "stairville/led-flood-panel-150",
            manufacturer: "Stairville",
            name: "LED Flood Panel 150",
            categories: ["Color Changer"],
            modes: [
                OFLFixtureMode(name: "3-channel", shortName: "3ch", channels: [
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                ]),
                OFLFixtureMode(name: "4-channel", shortName: "4ch", channels: [
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                ]),
                OFLFixtureMode(name: "8-channel", shortName: "8ch", channels: [
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                    .init(name: "Strobe", role: .strobe),
                    .init(name: "Programs", role: .other),
                    .init(name: "Auto / Sound", role: .other),
                    .init(name: "Speed", role: .other),
                ]),
            ],
            lumens: 1800,
            beamAngleMin: 40,
            beamAngleMax: 40,
            dimensionsMM: SIMD3<Float>(240, 155, 110)
        ))

        // 7. Stairville Octagon Theater 20x6W CW/WW/A
        register(OFLFixtureDefinition(
            id: "stairville/octagon-theater-20x6w-cw-ww-a",
            manufacturer: "Stairville",
            name: "Octagon Theater CW/WW/A",
            categories: ["Color Changer"],
            modes: [
                OFLFixtureMode(name: "4-Channel", shortName: "4ch", channels: [
                    .init(name: "Cold White", role: .coldWhite),
                    .init(name: "Warm White", role: .warmWhite),
                    .init(name: "Amber", role: .amber),
                    .init(name: "Dimmer", role: .dimmer),
                ]),
                OFLFixtureMode(name: "5-Channel", shortName: "5ch", channels: [
                    .init(name: "Cold White", role: .coldWhite),
                    .init(name: "Warm White", role: .warmWhite),
                    .init(name: "Amber", role: .amber),
                    .init(name: "Strobe", role: .strobe),
                    .init(name: "Dimmer", role: .dimmer),
                ]),
            ],
            lumens: 3200,
            beamAngleMin: 36,
            beamAngleMax: 36,
            dimensionsMM: SIMD3<Float>(340, 305, 195),
            colorTemperatureKelvin: 3200
        ))

        // 8. ADJ Ikon Profile
        register(OFLFixtureDefinition(
            id: "american-dj/ikon-profile",
            manufacturer: "ADJ",
            name: "Ikon Profile",
            categories: ["Dimmer"],
            modes: [
                OFLFixtureMode(name: "3 Chanel", shortName: "3ch", channels: [
                    .init(name: "Strobe", role: .strobe),
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Dimmer Mod", role: .other),
                ]),
            ],
            lumens: 1600,
            beamAngleMin: 15,
            beamAngleMax: 30,
            dimensionsMM: SIMD3<Float>(150, 147, 408),
            colorTemperatureKelvin: 5600
        ))

        // 9. Cameo Thunder Wash 600 W
        register(OFLFixtureDefinition(
            id: "cameo/thunder-wash-600-w",
            manufacturer: "Cameo",
            name: "Thunder Wash 600 W",
            categories: ["Strobe", "Blinder"],
            modes: [
                OFLFixtureMode(name: "1-channel", shortName: "1ch", channels: [
                    .init(name: "Strobe", role: .dimmer),
                ]),
                OFLFixtureMode(name: "2-channel", shortName: "2ch", channels: [
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Strobe", role: .strobe),
                ]),
            ],
            lumens: 6500,
            beamAngleMin: 75,
            beamAngleMax: 85,
            dimensionsMM: SIMD3<Float>(335, 182, 93),
            colorTemperatureKelvin: 6500
        ))

        // 10. Showtec Performer Profile Mini & Eurolite LED PLL-480 QCL Panel
        register(OFLFixtureDefinition(
            id: "showtec/performer-profile-mini",
            manufacturer: "Showtec",
            name: "Performer Profile Mini",
            categories: ["Dimmer"],
            modes: [
                OFLFixtureMode(name: "1-channel", shortName: "1ch", channels: [
                    .init(name: "Dimmer", role: .dimmer),
                ]),
                OFLFixtureMode(name: "2-channel", shortName: "2ch", channels: [
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Strobe", role: .strobe),
                ]),
            ],
            lumens: 1500,
            beamAngleMin: 19,
            beamAngleMax: 36,
            dimensionsMM: SIMD3<Float>(130, 231, 345),
            colorTemperatureKelvin: 3200
        ))

        register(OFLFixtureDefinition(
            id: "eurolite/led-pll-480-qcl",
            manufacturer: "Eurolite",
            name: "LED PLL-480 QCL Panel",
            categories: ["Color Changer"],
            modes: [
                OFLFixtureMode(name: "4-channel", shortName: "4ch", channels: [
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                    .init(name: "White", role: .white),
                ]),
                OFLFixtureMode(name: "6-channel", shortName: "6ch", channels: [
                    .init(name: "Dimmer", role: .dimmer),
                    .init(name: "Strobe", role: .strobe),
                    .init(name: "Red", role: .red),
                    .init(name: "Green", role: .green),
                    .init(name: "Blue", role: .blue),
                    .init(name: "White", role: .white),
                ]),
            ],
            lumens: 4500,
            beamAngleMin: 110,
            beamAngleMax: 120,
            dimensionsMM: SIMD3<Float>(640, 335, 130)
        ))
    }
}

// MARK: - Millumin Stage Light & Conduite Lumière (Lighting Cues)

/// A single column / cue in a Millumin dashboard (`FCBoardColumn`) containing light states (`FCLightStateMedia`).
public struct MilluminLightingCue: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    /// 0-based column index in the Millumin dashboard.
    public var columnIndex: Int
    /// Column title in Millumin (e.g. `"MISE"`, `"Entrée Public"`, `"NOIR DEBUT"`, `"FurFritz"`).
    public var title: String
    /// Transition duration in seconds (`0.0` if instant or no transition).
    public var transitionDuration: Float
    /// Channel values (`0 ... 255`) keyed by light name (`FCStageLightSharedProperties.name`).
    public var valuesByLightName: [String: [String: Float]]
    /// Channel values (`0 ... 255`) keyed by Millumin light `uid`.
    public var valuesByLightUID: [String: [String: Float]]

    public init(
        id: UUID = UUID(),
        columnIndex: Int,
        title: String,
        transitionDuration: Float = 0.0,
        valuesByLightName: [String: [String: Float]] = [:],
        valuesByLightUID: [String: [String: Float]] = [:]
    ) {
        self.id = id
        self.columnIndex = columnIndex
        self.title = title
        self.transitionDuration = transitionDuration
        self.valuesByLightName = valuesByLightName
        self.valuesByLightUID = valuesByLightUID
    }
}

/// Complete result of importing a `.millumin` project file: stage lights + lighting cue sheet (conduite).
public struct MilluminProjectImportResult: Sendable {
    public var boardName: String?
    public var lights: [MilluminStageLight]
    public var cues: [MilluminLightingCue]

    public init(boardName: String? = nil, lights: [MilluminStageLight], cues: [MilluminLightingCue] = []) {
        self.boardName = boardName
        self.lights = lights
        self.cues = cues
    }
}

/// Decoded stage light fixture from a Millumin project (`.millumin`).
public struct MilluminStageLight: Identifiable, Sendable {
    public var id: UUID
    public var milluminUID: String
    public var name: String
    public var fixtureIdentifier: String
    public var modeName: String
    public var dmxUniverse: Int
    public var dmxChannel: Int
    public var dmxMode: String
    public var filterColor: SIMD3<Float>?
    public var position: SIMD3<Float>
    public var rotation: SIMD3<Float>
    public var initialCueValues: [String: Float]

    public init(
        id: UUID = UUID(),
        milluminUID: String = "",
        name: String,
        fixtureIdentifier: String,
        modeName: String,
        dmxUniverse: Int = 0,
        dmxChannel: Int = 1,
        dmxMode: String = "dimmer1ch",
        filterColor: SIMD3<Float>? = nil,
        position: SIMD3<Float>,
        rotation: SIMD3<Float> = SIMD3<Float>(0, 180, 0),
        initialCueValues: [String: Float] = [:]
    ) {
        self.id = id
        self.milluminUID = milluminUID
        self.name = name
        self.fixtureIdentifier = fixtureIdentifier
        self.modeName = modeName
        self.dmxUniverse = dmxUniverse
        self.dmxChannel = dmxChannel
        self.dmxMode = dmxMode
        self.filterColor = filterColor
        self.position = position
        self.rotation = rotation
        self.initialCueValues = initialCueValues
    }

    /// Converts this imported Millumin stage light into a `VideoProjector` (with `isStageLight == true`) in SimpleSKP.
    public func toVideoProjector() -> VideoProjector {
        let oflFixture = OFLFixtureLibrary.shared.fixture(for: fixtureIdentifier)
        let oflMode = oflFixture?.resolveMode(named: modeName)

        let spec: ProjectorSpec
        if let oflFixture {
            spec = oflFixture.toProjectorSpec(modeName: modeName)
        } else {
            let idLower = (fixtureIdentifier + " " + name + " " + modeName).lowercased()
            if idLower.contains("340fx") || idLower.contains("340 fx") {
                spec = .varytecHeroWash340FX
            } else if idLower.contains("hero") || idLower.contains("varytec") || idLower.contains("300") {
                spec = .varytecHeroWash300FC
            } else if idLower.contains("ml-56") || idLower.contains("ml56") {
                spec = .euroliteLEDML56RGBW
            } else if idLower.contains("ikon") || idLower.contains("american-dj") {
                spec = .adjIkonProfile
            } else if idLower.contains("octagon") {
                spec = .stairvilleOctagonTheater
            } else if idLower.contains("flood-panel-150") || idLower.contains("flood panel") {
                spec = .stairvilleLEDFloodPanel150
            } else if idLower.contains("thunder") || idLower.contains("cameo") {
                spec = .cameoThunderWash600W
            } else if idLower.contains("profile") || idLower.contains("showtec") || idLower.contains("decoupe") {
                spec = .showtecPerformerProfileMini
            } else if idLower.contains("ers") {
                spec = .milluminTheatricalERS
            } else if idLower.contains("pll") || idLower.contains("480") || idLower.contains("dalle") {
                spec = .euroliteLEDPLL480QCL
            } else if idLower.contains("rgb") {
                spec = .milluminRGBWPar
            } else {
                spec = .milluminTheatricalPAR
            }
        }

        // Compute target point in SimpleSKP 3D space (Z up)
        var tgt = SIMD3<Float>(position.x, position.y, 0.0)
        let pitchDeg = rotation.x
        let yawDeg = rotation.y - 180.0
        if abs(pitchDeg) > 1.0 || abs(yawDeg) > 1.0 {
            let pitchRad = pitchDeg * .pi / 180.0
            let yawRad = yawDeg * .pi / 180.0
            let dx = sin(pitchRad) * cos(yawRad)
            let dy = sin(pitchRad) * sin(yawRad)
            let dz = -cos(pitchRad)
            let dir = simd_normalize(SIMD3<Float>(dx, dy, dz))
            let dist = max(position.z, 3.0)
            tgt = position + dir * dist
        }

        let chanNames = oflMode?.channels.map(\.name) ?? []
        let chanRoles = oflMode?.channels.map(\.role) ?? []

        let resolvedMode: String
        if !chanRoles.isEmpty {
            resolvedMode = "ofl"
        } else {
            let modeLower = modeName.lowercased()
            if modeLower.contains("6") {
                resolvedMode = "dimmerRgbw6ch"
            } else if modeLower.contains("4") || modeLower.contains("rgbw") {
                resolvedMode = "rgbw4ch"
            } else {
                resolvedMode = "dimmer1ch"
            }
        }

        let defaultWarmOrWhite: SIMD3<Float> = (spec.kind == .profileSpot || spec.colorTemperatureKelvin == 3200)
            ? SIMD3<Float>(1.0, 0.86, 0.68)
            : SIMD3<Float>(1.0, 1.0, 1.0)
        let color = filterColor ?? defaultWarmOrWhite

        var projector = VideoProjector(
            name: name.isEmpty ? "Lumière Millumin" : name,
            specID: spec.id,
            isEnabled: true,
            position: position,
            target: tgt,
            rollDegrees: 0,
            throwRatio: spec.defaultThrowRatio,
            lensShiftH: 0,
            lensShiftV: 0,
            intensity: 1.0,
            reverbIntensity: 1.0,
            pattern: .whiteFrame,
            showsFrustum: true,
            shutterTop: 0.0,
            shutterBottom: 0.0,
            shutterLeft: 0.0,
            shutterRight: 0.0,
            edgeSoftness: spec.kind == .profileSpot ? 0.05 : 0.85,
            lightColor: color,
            dmxUniverse: dmxUniverse,
            dmxChannel: dmxChannel,
            dmxMode: resolvedMode,
            oflFixtureID: oflFixture?.id ?? (fixtureIdentifier.isEmpty ? nil : fixtureIdentifier),
            oflModeName: oflMode?.name ?? (modeName.isEmpty ? nil : modeName),
            dmxChannelNames: chanNames,
            dmxChannelRoles: chanRoles
        )

        if !initialCueValues.isEmpty {
            _ = projector.applyMilluminCueValues(initialCueValues)
        }

        return projector
    }
}

/// Fast native parser for Millumin (`.millumin`) binary plist project files.
/// Extracts stage lighting fixtures (`FCStageLight`, `FCStageLightSharedProperties`, OFL fixtures, DMX patch & 3D poses)
/// as well as the full lighting cue sheet (`FCBoardColumn` / `FCLightStateMedia`).
public enum MilluminImporter {

    public enum ImportError: LocalizedError {
        case fileNotFound
        case invalidPlist
        case noStageLightsFound

        public var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return L("Fichier Millumin introuvable.", "Millumin file not found.")
            case .invalidPlist:
                return L("Le fichier Millumin n'a pas pu être décodé (format binary plist NSKeyedArchiver).",
                         "Could not decode Millumin file (binary plist NSKeyedArchiver format).")
            case .noStageLightsFound:
                return L("Aucun projecteur ou lumière de scène (FCStageLight) trouvé dans ce projet Millumin.",
                         "No stage lights (FCStageLight) found in this Millumin project.")
            }
        }
    }

    /// Returns `true` if `color` matches Millumin's default chartreuse plot icon color `(0.5501, 1.0, 0.1665)`.
    public static func isMilluminDefaultIconColor(_ color: SIMD3<Float>) -> Bool {
        abs(color.x - 0.5501) < 0.03 && abs(color.y - 1.0) < 0.03 && abs(color.z - 0.1665) < 0.03
    }

    /// Reads a `.millumin` project file and parses both the active board's `MilluminStageLight` list and its `MilluminLightingCue` conduite.
    public static func parseProjectFull(at url: URL) throws -> MilluminProjectImportResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.fileNotFound
        }

        let data = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else {
            throw ImportError.invalidPlist
        }

        func uidIndex(_ val: Any?) -> Int? {
            guard let v = val else { return nil }
            if CFGetTypeID(v as CFTypeRef) == CFKeyedArchiverUIDGetTypeID() {
                let idx = Int(CFKeyedArchiverUIDGetValue(v as AnyObject))
                if idx >= 0 && idx < objects.count {
                    return idx
                }
            }
            return nil
        }

        func resolveUID(_ val: Any) -> Any {
            if let idx = uidIndex(val) {
                return objects[idx]
            }
            return val
        }

        func className(of obj: Any) -> String? {
            guard let dict = obj as? [String: Any],
                  let classUID = dict["$class"],
                  let classDict = resolveUID(classUID) as? [String: Any] else {
                return nil
            }
            return classDict["$classname"] as? String
        }

        func extractString(_ val: Any?) -> String? {
            guard let v = val else { return nil }
            let resolved = resolveUID(v)
            if let str = resolved as? String {
                return str
            }
            if let dict = resolved as? [String: Any], let s = dict["NS.string"] as? String {
                return s
            }
            return nil
        }

        func extractNSArray(_ val: Any?) -> [Any] {
            guard let v = val else { return [] }
            let resolved = resolveUID(v)
            if let dict = resolved as? [String: Any] {
                if let objs = dict["NS.objects"] as? [Any] {
                    return objs.map { resolveUID($0) }
                }
                if let inner = dict["$0"] {
                    return extractNSArray(inner)
                }
            }
            return []
        }

        func extractFloat3(_ val: Any?) -> SIMD3<Float>? {
            guard let v = val else { return nil }
            let resolved = resolveUID(v)
            guard let dict = resolved as? [String: Any] else { return nil }

            let targetDict: [String: Any]
            if let sub1 = dict["$1"], let d1 = resolveUID(sub1) as? [String: Any] {
                targetDict = d1
            } else {
                targetDict = dict
            }

            guard let num0 = targetDict["$0"] as? NSNumber,
                  let num1 = targetDict["$1"] as? NSNumber,
                  let num2 = targetDict["$2"] as? NSNumber else {
                return nil
            }
            return SIMD3<Float>(num0.floatValue, num1.floatValue, num2.floatValue)
        }

        func extractColor(_ val: Any?) -> SIMD3<Float>? {
            guard let v = val else { return nil }
            let resolved = resolveUID(v)
            guard let dict = resolved as? [String: Any],
                  let rawData = dict["NSRGB"] as? Data,
                  let str = String(data: rawData, encoding: .ascii) else {
                return nil
            }
            let parts = str.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
                .components(separatedBy: CharacterSet.whitespaces)
            guard parts.count >= 3,
                  let r = Float(parts[0]),
                  let g = Float(parts[1]),
                  let b = Float(parts[2]) else {
                return nil
            }
            let color = SIMD3<Float>(r, g, b)
            // Ignore Millumin's default chartreuse UI plot icon color
            if isMilluminDefaultIconColor(color) {
                return nil
            }
            return color
        }

        func parseSharedPropertiesDict(_ dict: [String: Any]) -> MilluminStageLight {
            let uid = extractString(dict["uid"]) ?? UUID().uuidString
            let name = extractString(dict["name"]) ?? "Lumière Millumin"
            let fixtureIdentifier = extractString(dict["fixtureIdentifier"]) ?? ""
            let modeName = extractString(dict["modeName"]) ?? ""
            let dmxChannel = (dict["dmxChannel"] as? NSNumber)?.intValue ?? 1
            let color = extractColor(dict["filterColor"])

            var position = SIMD3<Float>(0, 0, 4.5)
            if let rawPos = extractFloat3(dict["positionInScene"]) {
                let skpX = rawPos.x
                let skpY = -rawPos.z
                let skpZ = rawPos.y > 0.05 ? rawPos.y : 4.5
                position = SIMD3<Float>(skpX, skpY, skpZ)
            }

            var rotation = SIMD3<Float>(0, 180, 0)
            if let rawRot = extractFloat3(dict["rotationInScene"]) {
                rotation = rawRot
            }

            return MilluminStageLight(
                milluminUID: uid,
                name: name,
                fixtureIdentifier: fixtureIdentifier,
                modeName: modeName,
                dmxUniverse: 0,
                dmxChannel: dmxChannel,
                filterColor: color,
                position: position,
                rotation: rotation
            )
        }

        // 1. Locate all FCBoard objects and prefer the active one (via FCController.board / currentBoard, or the FCBoard containing FCLightGroup / FCLightStateMedia)
        var allBoardDicts: [[String: Any]] = []
        for obj in objects {
            if let d = obj as? [String: Any], className(of: d) == "FCBoard" {
                allBoardDicts.append(d)
            }
        }

        var boardDict: [String: Any]?
        for obj in objects {
            guard let d = obj as? [String: Any] else { continue }
            let cls = className(of: d)
            if cls == "FCController" || cls == "FCProject" {
                if let bRef = d["board"] ?? d["currentBoard"],
                   let resolved = resolveUID(bRef) as? [String: Any],
                   className(of: resolved) == "FCBoard" {
                    boardDict = resolved
                    break
                }
            }
        }
        // Prefer a board whose topGroup actually contains FCLightGroup or FCStageLight
        if let preferred = allBoardDicts.first(where: { b in
            guard let tg = b["topGroup"].map({ resolveUID($0) }) as? [String: Any] else { return false }
            return extractNSArray(tg["elements"]).contains { el in
                guard let ed = el as? [String: Any] else { return false }
                let c = className(of: ed)
                return c == "FCLightGroup" || c == "FCStageLight"
            }
        }) {
            boardDict = preferred
        } else if boardDict == nil {
            boardDict = allBoardDicts.first
        }

        let boardName = boardDict.flatMap { extractString($0["name"]) }

        // 2. Extract FCStageLightSharedProperties from active board's FCLightGroup (preserving Millumin layer order)
        var results: [MilluminStageLight] = []
        var seenUIDs = Set<String>()

        if let boardDict,
           let topGroup = boardDict["topGroup"].map({ resolveUID($0) }) as? [String: Any] {
            let topElements = extractNSArray(topGroup["elements"])
            for el in topElements {
                guard let elDict = el as? [String: Any] else { continue }
                let cls = className(of: elDict)
                if cls == "FCLightGroup" {
                    let lightLayers = extractNSArray(elDict["elements"])
                    for lightLayer in lightLayers {
                        guard let llDict = lightLayer as? [String: Any],
                              className(of: llDict) == "FCStageLight",
                              let spRef = llDict["sharedProperties"],
                              let spDict = resolveUID(spRef) as? [String: Any],
                              className(of: spDict) == "FCStageLightSharedProperties" else {
                            continue
                        }
                        let parsed = parseSharedPropertiesDict(spDict)
                        if !seenUIDs.contains(parsed.milluminUID) {
                            seenUIDs.insert(parsed.milluminUID)
                            results.append(parsed)
                        }
                    }
                } else if cls == "FCStageLight",
                          let spRef = elDict["sharedProperties"],
                          let spDict = resolveUID(spRef) as? [String: Any],
                          className(of: spDict) == "FCStageLightSharedProperties" {
                    let parsed = parseSharedPropertiesDict(spDict)
                    if !seenUIDs.contains(parsed.milluminUID) {
                        seenUIDs.insert(parsed.milluminUID)
                        results.append(parsed)
                    }
                }
            }
        }

        // Fallback if currentBoard had no FCLightGroup: scan all FCStageLightSharedProperties deduplicated by uid
        if results.isEmpty {
            for obj in objects {
                guard let dict = obj as? [String: Any],
                      className(of: dict) == "FCStageLightSharedProperties" else {
                    continue
                }
                let parsed = parseSharedPropertiesDict(dict)
                if !seenUIDs.contains(parsed.milluminUID) {
                    seenUIDs.insert(parsed.milluminUID)
                    results.append(parsed)
                }
            }
        }

        guard !results.isEmpty else {
            throw ImportError.noStageLightsFound
        }

        // 3. Extract Lighting Cue Sheet (Conduite Lumière) from board's columnAndSections (checking all boards if needed)
        func extractPairs(_ raw: Any?) -> [(Any, Any)] {
            guard let raw else { return [] }
            let resolved = resolveUID(raw)
            guard let dict = resolved as? [String: Any] else { return [] }
            if let keys = dict["NS.keys"] as? [Any], let objs = dict["NS.objects"] as? [Any] {
                return Array(zip(keys.map { resolveUID($0) }, objs.map { resolveUID($0) }))
            }
            var tableDict: [String: Any]?
            if dict["NS.count"] != nil {
                tableDict = dict
            } else {
                for subKey in ["$0", "$1", "NS.objects"] {
                    if let inner = dict[subKey].flatMap({ resolveUID($0) as? [String: Any] }), inner["NS.count"] != nil {
                        tableDict = inner
                        break
                    }
                }
            }
            guard let td = tableDict else { return [] }
            let count = (td["NS.count"] as? NSNumber)?.intValue ?? 0
            guard count > 0 else { return [] }
            // In NSKeyedArchiver, NSMapTable stores pointerFunction flags at "$0" and "$1",
            // and the actual key/value pairs start at "$2" / "$3", "$4" / "$5", etc.
            let baseOffset = (td["$0"] is NSNumber && td["$1"] is NSNumber) ? 2 : 0
            var pairs: [(Any, Any)] = []
            for idx in 0..<count {
                if let kRef = td["$\(baseOffset + 2 * idx)"], let vRef = td["$\(baseOffset + 2 * idx + 1)"] {
                    pairs.append((resolveUID(kRef), resolveUID(vRef)))
                }
            }
            return pairs
        }

        var cues: [MilluminLightingCue] = []
        let candidateBoards = (boardDict.map { [$0] } ?? []) + allBoardDicts
        for candidateBoard in candidateBoards where cues.isEmpty {
            let columns = extractNSArray(candidateBoard["columnAndSections"] ?? candidateBoard["columns"])
            var colIndex = 0
            for colObj in columns {
                guard let colDict = colObj as? [String: Any],
                      className(of: colDict) == "FCBoardColumn" else {
                    continue
                }
                let rawTitle = (extractString(colDict["title"]) ?? extractString(colDict["name"]))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let cueTitle = rawTitle.isEmpty ? "Colonne \(colIndex + 1)" : rawTitle

                var transitionSec: Float = 0.0
                if let ltRef = colDict["lightTransition"],
                   let ltDict = resolveUID(ltRef) as? [String: Any],
                   let ms = (ltDict["transitionTime"] as? NSNumber)?.floatValue {
                    transitionSec = max(0, ms / 1000.0)
                } else if let mtRef = colDict["mainTransition"],
                          let mtDict = resolveUID(mtRef) as? [String: Any],
                          let ms = (mtDict["transitionTime"] as? NSNumber)?.floatValue {
                    transitionSec = max(0, ms / 1000.0)
                }

                var valuesByName: [String: [String: Float]] = [:]
                var valuesByUID: [String: [String: Float]] = [:]

                for (_, mediaObj) in extractPairs(colDict["mediasPerLayer"]) {
                    guard let mediaDict = mediaObj as? [String: Any],
                          className(of: mediaDict) == "FCLightStateMedia" else {
                        continue
                    }
                    for (lightPropObj, valObj) in extractPairs(mediaDict["valuesPerLight"]) {
                        guard let lightPropDict = lightPropObj as? [String: Any],
                              let valDict = valObj as? [String: Any] else {
                            continue
                        }
                        let lightName = extractString(lightPropDict["name"]) ?? ""
                        let lightUID: String
                        if let strUID = extractString(lightPropDict["uid"]) {
                            lightUID = strUID
                        } else if let numUID = lightPropDict["uid"].map({ resolveUID($0) }) as? NSNumber {
                            lightUID = numUID.stringValue
                        } else {
                            lightUID = ""
                        }

                        var channelMap: [String: Float] = [:]
                        for (kObj, vObj) in extractPairs(valDict) {
                            let keyStr = (kObj as? String) ?? extractString(kObj) ?? ""
                            guard !keyStr.isEmpty else { continue }
                            if let num = vObj as? NSNumber {
                                channelMap[keyStr] = num.floatValue
                            } else if let str = (vObj as? String) ?? extractString(vObj), let f = Float(str) {
                                channelMap[keyStr] = f
                            }
                        }
                        if !channelMap.isEmpty {
                            if !lightName.isEmpty {
                                valuesByName[lightName] = channelMap
                            }
                            if !lightUID.isEmpty {
                                valuesByUID[lightUID] = channelMap
                            }
                        }
                    }
                }

                if !valuesByName.isEmpty || !valuesByUID.isEmpty {
                    cues.append(MilluminLightingCue(
                        columnIndex: colIndex,
                        title: cueTitle,
                        transitionDuration: transitionSec,
                        valuesByLightName: valuesByName,
                        valuesByLightUID: valuesByUID
                    ))
                }
                colIndex += 1
            }
        }

        // Attach the first non-black cue's values (or first cue) as initialCueValues so imported lights immediately show their stage look
        if let firstActiveCue = cues.first(where: { cue in
            cue.valuesByLightName.values.contains(where: { dict in
                dict.values.contains(where: { $0 > 1.0 })
            })
        }) ?? cues.first {
            for i in results.indices {
                let uid = results[i].milluminUID
                let name = results[i].name
                if let vals = firstActiveCue.valuesByLightUID[uid] ?? firstActiveCue.valuesByLightName[name] {
                    results[i].initialCueValues = vals
                }
            }
        }

        return MilluminProjectImportResult(
            boardName: boardName,
            lights: results,
            cues: cues
        )
    }

    /// Reads a `.millumin` project file and parses all `FCStageLight` objects into `MilluminStageLight`.
    public static func parseProject(at url: URL) throws -> [MilluminStageLight] {
        try parseProjectFull(at: url).lights
    }

    /// Imports all stage lights from a `.millumin` file directly as `VideoProjector`s for SimpleSKP.
    public static func importProjectors(from url: URL) throws -> [VideoProjector] {
        let lights = try parseProject(at: url)
        return lights.map { $0.toVideoProjector() }
    }
}
