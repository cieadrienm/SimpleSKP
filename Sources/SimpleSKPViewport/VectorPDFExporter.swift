import AppKit
import CoreGraphics
import Foundation
import simd
import SimpleSKPCore

/// Renders the current 3D view of a `ViewportScene` / `SKPModel` into a 100% vector PDF document (`Data`).
/// Preserves perspective or parallel projection, camera FOV, shading style (`.textured`, `.clay`, `.xray`, `.wireframe`),
/// adaptive contrasting edge colors, sun/point/ambient lighting, backdrop gradient, and optional ground grid.
public enum VectorPDFExporter {
    public struct Options: Sendable {
        public var pageSize: CGSize
        public var pose: CameraRig.Pose
        public var isPerspective: Bool
        public var fovDegrees: Float
        public var orthographicScale: Float
        public var exposureOffset: Float
        public var shadingStyle: ShadingStyle
        public var showsEdges: Bool
        public var showsGrid: Bool
        public var backdropStyle: BackdropStyle
        public var customBackdropColor: SIMD3<Float>
        public var lightingMode: LightingMode
        public var sunAzimuthDegrees: Float
        public var sunElevationDegrees: Float
        public var sunIntensity: Float
        public var pointLights: [ViewportPointLight]
        public var ambientIntensity: Float
        public var visibleLayers: [Bool]

        public init(
            pageSize: CGSize = CGSize(width: 1440, height: 900),
            pose: CameraRig.Pose,
            isPerspective: Bool = true,
            fovDegrees: Float = 35,
            orthographicScale: Float = 5,
            exposureOffset: Float = -0.62,
            shadingStyle: ShadingStyle = .textured,
            showsEdges: Bool = true,
            showsGrid: Bool = false,
            backdropStyle: BackdropStyle = .architecturalSky,
            customBackdropColor: SIMD3<Float> = Rendering.defaultCustomBackdropColor,
            lightingMode: LightingMode = .sun,
            sunAzimuthDegrees: Float = -135,
            sunElevationDegrees: Float = 45,
            sunIntensity: Float = 1.0,
            pointLights: [ViewportPointLight] = [],
            ambientIntensity: Float = 1.0,
            visibleLayers: [Bool] = []
        ) {
            self.pageSize = pageSize
            self.pose = pose
            self.isPerspective = isPerspective
            self.fovDegrees = fovDegrees
            self.orthographicScale = orthographicScale
            self.exposureOffset = exposureOffset
            self.shadingStyle = shadingStyle
            self.showsEdges = showsEdges
            self.showsGrid = showsGrid
            self.backdropStyle = backdropStyle
            self.customBackdropColor = customBackdropColor
            self.lightingMode = lightingMode
            self.sunAzimuthDegrees = sunAzimuthDegrees
            self.sunElevationDegrees = sunElevationDegrees
            self.sunIntensity = sunIntensity
            self.pointLights = pointLights
            self.ambientIntensity = ambientIntensity
            self.visibleLayers = visibleLayers
        }
    }

    /// Convenience entry point on the main actor reading all current parameters from a `ViewportView` and its `ViewportScene`.
    @MainActor
    public static func renderPDF(from viewport: ViewportView, visibleLayers: [Bool]? = nil, pageSize: CGSize? = nil) -> Data? {
        guard let vpScene = viewport.viewportScene else { return nil }
        let model = vpScene.model
        let rawSize = pageSize ?? viewport.bounds.size
        let width = max(320, rawSize.width > 10 ? rawSize.width : 1440)
        let height = max(240, rawSize.height > 10 ? rawSize.height : 900)
        let layers = visibleLayers ?? model.layers.map(\.isVisible)

        let options = Options(
            pageSize: CGSize(width: width, height: height),
            pose: viewport.cameraPose,
            isPerspective: viewport.isPerspective,
            fovDegrees: viewport.fieldOfView,
            orthographicScale: viewport.orthographicScale,
            exposureOffset: viewport.exposureOffset,
            shadingStyle: vpScene.shadingStyle,
            showsEdges: vpScene.showsEdges,
            showsGrid: vpScene.showsGrid,
            backdropStyle: vpScene.backdropStyle,
            customBackdropColor: vpScene.customBackdropColor,
            lightingMode: vpScene.lightingMode,
            sunAzimuthDegrees: vpScene.sunAzimuthDegrees,
            sunElevationDegrees: vpScene.sunElevationDegrees,
            sunIntensity: vpScene.sunIntensity,
            pointLights: vpScene.pointLights,
            ambientIntensity: vpScene.ambientIntensity,
            visibleLayers: layers
        )
        return renderPDF(model: model, options: options)
    }

    /// Renders `model` with `options` into a single-page vector PDF `Data`.
    public static func renderPDF(model: SKPModel, options: Options) -> Data? {
        let width = max(64.0, options.pageSize.width)
        let height = max(64.0, options.pageSize.height)
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        let pageInfo: [CFString: Any] = [
            kCGPDFContextTitle: model.fileInfo.url.deletingPathExtension().lastPathComponent,
            kCGPDFContextCreator: "SimpleSKP — cie Adrien M",
        ]
        ctx.beginPDFPage(pageInfo as CFDictionary)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)

        // 1. Draw vector gradient backdrop
        drawBackdrop(in: ctx, size: mediaBox.size, style: options.backdropStyle, customColor: options.customBackdropColor)

        // 2. Setup camera projector
        let projector = Projector(
            pose: options.pose,
            isPerspective: options.isPerspective,
            fovDegrees: options.fovDegrees,
            orthographicScale: options.orthographicScale,
            pageSize: mediaBox.size
        )

        // 3. Optional ground grid & XYZ axes
        if options.showsGrid {
            drawGrid(in: ctx, model: model, projector: projector, options: options)
        }

        // 4. Collect visible 3D primitives & project to 2D
        let materialColors = resolveMaterialColors(for: model)
        let edgeRGB = Rendering.contrastingEdgeColor(
            for: options.backdropStyle,
            customColor: options.customBackdropColor,
            shadingStyle: options.shadingStyle
        )

        var triangles: [ProjectedTriangle] = []
        var edges: [ProjectedEdge] = []

        let drawFaces = options.shadingStyle != .wireframe
        let drawEdges = options.showsEdges || options.shadingStyle == .wireframe
        let edgeBias = max(0.0015, options.pose.distance * 0.0008)

        let lighting = LightingRig(model: model, options: options)

        func isLayerVisible(_ layerIndex: Int) -> Bool {
            guard options.visibleLayers.indices.contains(layerIndex) else { return true }
            return options.visibleLayers[layerIndex]
        }

        func visit(definitionIndex: Int, transform: simd_float4x4, inheritedMaterial: Int?, pathLayers: [Int]) {
            guard pathLayers.allSatisfy(isLayerVisible) else { return }
            let def = definitionIndex < 0 ? model.root : model.definitions[definitionIndex]

            if drawFaces {
                let linear = simd_float3x3(
                    SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                    SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                    SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
                )
                let normalMatrix = linear.inverse.transpose
                let flipped = simd_determinant(linear) < 0

                for mesh in def.meshes where isLayerVisible(mesh.layer) {
                    let matIdx = mesh.material ?? inheritedMaterial
                    let (baseColor, opacity) = faceAppearance(
                        materialIndex: matIdx,
                        materialColors: materialColors,
                        shadingStyle: options.shadingStyle
                    )

                    let posCount = mesh.positions.count
                    guard posCount >= 3 else { continue }
                    var worldPos = [SIMD3<Float>](repeating: .zero, count: posCount)
                    for i in 0..<posCount {
                        let wp = transform * SIMD4(mesh.positions[i], 1)
                        worldPos[i] = SIMD3(wp.x, wp.y, wp.z)
                    }

                    var t = 0
                    let idxCount = mesh.indices.count
                    while t + 2 < idxCount {
                        let i0 = Int(mesh.indices[t])
                        let i1 = Int(mesh.indices[t + (flipped ? 2 : 1)])
                        let i2 = Int(mesh.indices[t + (flipped ? 1 : 2)])
                        t += 3
                        guard i0 < posCount, i1 < posCount, i2 < posCount else { continue }

                        let p0 = worldPos[i0], p1 = worldPos[i1], p2 = worldPos[i2]
                        let rawNormal: SIMD3<Float>
                        if i0 < mesh.normals.count {
                            rawNormal = normalMatrix * mesh.normals[i0]
                        } else {
                            rawNormal = simd_cross(p1 - p0, p2 - p0)
                        }
                        let nLen = simd_length(rawNormal)
                        let worldNormal = nLen > 1e-6 ? (rawNormal / nLen) : SIMD3<Float>(0, 0, 1)

                        let centroid = (p0 + p1 + p2) * (1.0 / 3.0)
                        let shadedRGB = lighting.shade(
                            point: centroid,
                            normal: worldNormal,
                            eye: options.pose.position,
                            baseColor: baseColor
                        )

                        for poly in projector.projectTriangle(p0, p1, p2) {
                            triangles.append(ProjectedTriangle(
                                p0: poly.0,
                                p1: poly.1,
                                p2: poly.2,
                                depth: poly.3,
                                area: poly.4,
                                color: shadedRGB,
                                alpha: opacity
                            ))
                        }
                    }
                }
            }

            if drawEdges {
                for edgeSet in def.edges where isLayerVisible(edgeSet.layer) && edgeSet.positions.count >= 2 {
                    var i = 0
                    let count = edgeSet.positions.count
                    while i + 1 < count {
                        let w0 = transform * SIMD4(edgeSet.positions[i], 1)
                        let w1 = transform * SIMD4(edgeSet.positions[i + 1], 1)
                        i += 2
                        let p0 = SIMD3<Float>(w0.x, w0.y, w0.z)
                        let p1 = SIMD3<Float>(w1.x, w1.y, w1.z)
                        if let seg = projector.projectSegment(p0, p1, depthBias: edgeBias) {
                            edges.append(seg)
                        }
                    }
                }
            }

            for child in def.children where isLayerVisible(child.layer) {
                let nextLayers = pathLayers.contains(child.layer) ? pathLayers : (pathLayers + [child.layer])
                visit(
                    definitionIndex: child.definition,
                    transform: transform * child.transform,
                    inheritedMaterial: child.material ?? inheritedMaterial,
                    pathLayers: nextLayers
                )
            }
        }

        visit(definitionIndex: -1, transform: matrix_identity_float4x4, inheritedMaterial: nil, pathLayers: [])

        // 5. Emit vector paths
        if !drawFaces {
            // Pure wireframe mode: batch all visible edges into crisp vector strokes
            drawWireframeEdges(edges, color: edgeRGB, in: ctx)
        } else {
            drawShadedScene(triangles: triangles, edges: edges, edgeColor: edgeRGB, shadingStyle: options.shadingStyle, in: ctx)
        }

        ctx.endPDFPage()
        ctx.closePDF()
        return pdfData as Data
    }

    // MARK: - Vector Drawing Helpers

    private static func drawBackdrop(
        in ctx: CGContext,
        size: CGSize,
        style: BackdropStyle,
        customColor: SIMD3<Float>
    ) {
        let stops = Rendering.backdropGradientStops(for: style, customColor: customBackdropColor(style: style, custom: customColor))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let colors: [CGColor] = [
            CGColor(srgbRed: CGFloat(stops.bottom.x), green: CGFloat(stops.bottom.y), blue: CGFloat(stops.bottom.z), alpha: 1.0),
            CGColor(srgbRed: CGFloat(stops.mid.x), green: CGFloat(stops.mid.y), blue: CGFloat(stops.mid.z), alpha: 1.0),
            CGColor(srgbRed: CGFloat(stops.top.x), green: CGFloat(stops.top.y), blue: CGFloat(stops.top.z), alpha: 1.0),
        ]
        let locations: [CGFloat] = [0.0, 0.42, 1.0]
        if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 0, y: size.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    private static func customBackdropColor(style: BackdropStyle, custom: SIMD3<Float>) -> SIMD3<Float> {
        style == .customColor ? custom : Rendering.defaultCustomBackdropColor
    }

    private static func drawGrid(
        in ctx: CGContext,
        model: SKPModel,
        projector: Projector,
        options: Options
    ) {
        let span = max(simd_length(model.boundsMax - model.boundsMin), 2.0)
        let rawStep = pow(10, floor(log10(max(span / 12, 0.1))))
        let step: Float = span / rawStep > 25 ? rawStep * 2 : (span / rawStep < 8 ? rawStep / 2 : rawStep)
        let halfExtent = ceil((span * 0.85) / (step * 5)) * (step * 5)
        let cx = ((model.boundsMin.x + model.boundsMax.x) * 0.5 / (step * 5)).rounded() * (step * 5)
        let cy = ((model.boundsMin.y + model.boundsMax.y) * 0.5 / (step * 5)).rounded() * (step * 5)
        let z: Float = (model.boundsMin.z <= 0.1 && model.boundsMax.z >= -0.1) ? 0 : model.boundsMin.z

        let luma = Rendering.backdropLuminance(for: options.backdropStyle, customColor: options.customBackdropColor)
        let gridGray: CGFloat = luma < 0.52 ? 0.78 : 0.25

        ctx.saveGState()
        let count = Int((halfExtent / step).rounded())
        ctx.setLineWidth(0.4)
        ctx.setStrokeColor(CGColor(srgbRed: gridGray, green: gridGray, blue: gridGray, alpha: 0.22))
        for i in -count...count where i % 5 != 0 {
            let offset = Float(i) * step
            stroke3DSegment(SIMD3(cx + offset, cy - halfExtent, z), SIMD3(cx + offset, cy + halfExtent, z), projector: projector, in: ctx)
            stroke3DSegment(SIMD3(cx - halfExtent, cy + offset, z), SIMD3(cx + halfExtent, cy + offset, z), projector: projector, in: ctx)
        }
        ctx.strokePath()

        ctx.setLineWidth(0.65)
        ctx.setStrokeColor(CGColor(srgbRed: gridGray, green: gridGray, blue: gridGray, alpha: 0.40))
        for i in -count...count where i % 5 == 0 {
            let offset = Float(i) * step
            stroke3DSegment(SIMD3(cx + offset, cy - halfExtent, z), SIMD3(cx + offset, cy + halfExtent, z), projector: projector, in: ctx)
            stroke3DSegment(SIMD3(cx - halfExtent, cy + offset, z), SIMD3(cx + halfExtent, cy + offset, z), projector: projector, in: ctx)
        }
        ctx.strokePath()

        let axisLen = max(halfExtent * 0.6, step * 4)
        let origin = SIMD3<Float>(0, 0, z + 0.002)
        ctx.setLineWidth(1.1)
        ctx.setStrokeColor(CGColor(srgbRed: 0.92, green: 0.28, blue: 0.26, alpha: 0.88))
        stroke3DSegment(origin, origin + SIMD3(axisLen, 0, 0), projector: projector, in: ctx)
        ctx.strokePath()

        ctx.setStrokeColor(CGColor(srgbRed: 0.30, green: 0.76, blue: 0.38, alpha: 0.88))
        stroke3DSegment(origin, origin + SIMD3(0, axisLen, 0), projector: projector, in: ctx)
        ctx.strokePath()

        ctx.setStrokeColor(CGColor(srgbRed: 0.28, green: 0.56, blue: 0.96, alpha: 0.88))
        stroke3DSegment(origin, origin + SIMD3(0, 0, axisLen * 0.6), projector: projector, in: ctx)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func stroke3DSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>, projector: Projector, in ctx: CGContext) {
        if let seg = projector.projectSegment(a, b, depthBias: 0) {
            ctx.move(to: seg.p0)
            ctx.addLine(to: seg.p1)
        }
    }

    private static func drawWireframeEdges(_ edges: [ProjectedEdge], color: SIMD3<Float>, in ctx: CGContext) {
        guard !edges.isEmpty else { return }
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(edges.count > 120_000 ? 0.38 : 0.62)
        ctx.setStrokeColor(CGColor(srgbRed: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 0.94))

        let minLength: CGFloat = edges.count > 160_000 ? 0.55 : 0.05
        var inBatch = 0
        for edge in edges where edge.length >= minLength {
            ctx.move(to: edge.p0)
            ctx.addLine(to: edge.p1)
            inBatch += 1
            if inBatch >= 4096 {
                ctx.strokePath()
                inBatch = 0
            }
        }
        if inBatch > 0 {
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func drawShadedScene(
        triangles: [ProjectedTriangle],
        edges: [ProjectedEdge],
        edgeColor: SIMD3<Float>,
        shadingStyle: ShadingStyle,
        in ctx: CGContext
    ) {
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let minTriArea: CGFloat = triangles.count > 150_000 ? 0.35 : 0.02
        let minEdgeLen: CGFloat = edges.count > 150_000 ? 0.55 : 0.05

        enum Item {
            case tri(Int)
            case edge(Int)
        }

        var items: [(depth: Float, item: Item)] = []
        items.reserveCapacity(triangles.count + edges.count)

        for (i, t) in triangles.enumerated() where t.area >= minTriArea {
            items.append((t.depth, .tri(i)))
        }
        for (i, e) in edges.enumerated() where e.length >= minEdgeLen {
            items.append((e.depth, .edge(i)))
        }

        // Painter's algorithm: farthest first, nearest last
        items.sort { $0.depth > $1.depth }

        let edgeCGColor = CGColor(
            srgbRed: CGFloat(edgeColor.x),
            green: CGFloat(edgeColor.y),
            blue: CGFloat(edgeColor.z),
            alpha: shadingStyle == .xray ? 0.72 : 0.90
        )
        let edgeLineWidth: CGFloat = edges.count > 120_000 ? 0.35 : 0.52

        for entry in items {
            switch entry.item {
            case .tri(let idx):
                let tri = triangles[idx]
                let c = CGColor(
                    srgbRed: CGFloat(tri.color.x),
                    green: CGFloat(tri.color.y),
                    blue: CGFloat(tri.color.z),
                    alpha: CGFloat(tri.alpha)
                )
                ctx.setFillColor(c)
                ctx.beginPath()
                ctx.move(to: tri.p0)
                ctx.addLine(to: tri.p1)
                ctx.addLine(to: tri.p2)
                ctx.closePath()
                if tri.alpha >= 0.98 {
                    // Hairline same-color stroke prevents sub-pixel seam cracks between coplanar triangles in PDF viewers
                    ctx.setStrokeColor(c)
                    ctx.setLineWidth(0.22)
                    ctx.drawPath(using: .fillStroke)
                } else {
                    ctx.fillPath()
                }
            case .edge(let idx):
                let edge = edges[idx]
                ctx.setStrokeColor(edgeCGColor)
                ctx.setLineWidth(edgeLineWidth)
                ctx.beginPath()
                ctx.move(to: edge.p0)
                ctx.addLine(to: edge.p1)
                ctx.strokePath()
            }
        }
        ctx.restoreGState()
    }

    // MARK: - Materials & Lighting

    private static func resolveMaterialColors(for model: SKPModel) -> [(rgb: SIMD3<Float>, opacity: Float)] {
        model.materials.map { mat in
            var rgb = SIMD3<Float>(mat.color.x, mat.color.y, mat.color.z)
            if let url = mat.textureURL, let avg = averageTextureColor(at: url) {
                // Blend texture average color with SketchUp material tint
                let tintLuma = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
                rgb = tintLuma > 0.95 ? avg : simd_clamp(avg * rgb, .zero, SIMD3(repeating: 1))
            }
            return (rgb, simd_clamp(mat.opacity * mat.color.w, 0.05, 1.0))
        }
    }

    private static func averageTextureColor(at url: URL) -> SIMD3<Float>? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        let w = 8, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = SIMD3<Float>.zero
        var count: Float = 0
        for i in 0..<(w * h) {
            let a = Float(pixels[i * 4 + 3]) / 255.0
            guard a > 0.05 else { continue }
            sum += SIMD3<Float>(
                Float(pixels[i * 4]) / (255.0 * a),
                Float(pixels[i * 4 + 1]) / (255.0 * a),
                Float(pixels[i * 4 + 2]) / (255.0 * a)
            )
            count += 1
        }
        guard count > 0 else { return nil }
        return simd_clamp(sum / count, .zero, SIMD3(repeating: 1))
    }

    private static func faceAppearance(
        materialIndex: Int?,
        materialColors: [(rgb: SIMD3<Float>, opacity: Float)],
        shadingStyle: ShadingStyle
    ) -> (rgb: SIMD3<Float>, opacity: Float) {
        let resolved: (rgb: SIMD3<Float>, opacity: Float)
        if let idx = materialIndex, materialColors.indices.contains(idx) {
            resolved = materialColors[idx]
        } else {
            resolved = (SIMD3<Float>(0.95, 0.95, 0.94), 1.0)
        }

        switch shadingStyle {
        case .textured:
            return resolved
        case .clay:
            if resolved.opacity < 0.98 { return resolved }
            return (SIMD3<Float>(0.94, 0.92, 0.89), 1.0)
        case .xray:
            return (resolved.rgb, min(resolved.opacity, 0.36))
        case .wireframe:
            return (resolved.rgb, 0.0)
        }
    }

    private struct LightingRig {
        let isSun: Bool
        let toSun: SIMD3<Float>
        let toCounter: SIMD3<Float>
        let sunPower: Float
        let ambientPower: Float
        let pointLights: [ViewportPointLight]
        let falloffRadius: Float
        let exposureGain: Float

        init(model: SKPModel, options: Options) {
            self.isSun = options.lightingMode == .sun
            let az = options.sunAzimuthDegrees * .pi / 180.0
            let el = max(5.0, min(88.0, options.sunElevationDegrees)) * .pi / 180.0
            self.toSun = simd_normalize(SIMD3<Float>(cos(az) * cos(el), sin(az) * cos(el), sin(el)))
            let caz = az + .pi
            let cel: Float = 28.0 * .pi / 180.0
            self.toCounter = simd_normalize(SIMD3<Float>(cos(caz) * cos(cel), sin(caz) * cos(cel), sin(cel)))
            self.sunPower = pow(max(0, options.sunIntensity), 1.25)
            self.ambientPower = pow(max(0, options.ambientIntensity), 1.25)
            self.pointLights = options.pointLights
            let diag = max(simd_distance(model.boundsMin, model.boundsMax), 1.0)
            self.falloffRadius = max(diag * 0.65, 1.0)
            self.exposureGain = pow(2.0, (options.exposureOffset + 0.62) * 0.55)
        }

        func shade(point: SIMD3<Float>, normal: SIMD3<Float>, eye: SIMD3<Float>, baseColor: SIMD3<Float>) -> SIMD3<Float> {
            let toEye = eye - point
            let orientedN = simd_dot(normal, toEye) >= 0 ? normal : -normal

            var lightSum: Float = 0
            if isSun {
                let sunDiff = max(0, simd_dot(orientedN, toSun)) * 0.72 * sunPower
                let skyDiff = max(0, simd_dot(orientedN, toCounter)) * 0.16 * ambientPower
                let hemi = (0.5 + 0.5 * orientedN.z) * 0.24 * ambientPower
                let amb = 0.18 * ambientPower
                lightSum = sunDiff + skyDiff + hemi + amb
            } else {
                var omniTotal: Float = 0
                for pl in pointLights where pl.intensity > 0.0001 {
                    let delta = pl.position - point
                    let dist = max(simd_length(delta), 0.05)
                    let dir = delta / dist
                    let ndotl = max(0.12, abs(simd_dot(orientedN, dir)))
                    let t = min(1.0, dist / falloffRadius)
                    let atten = pow(1.0 - t * 0.82, 1.6)
                    let gain = pow(max(0, pl.intensity), 1.35)
                    omniTotal += ndotl * atten * gain * 0.95
                }
                let amb = 0.22 * ambientPower
                lightSum = omniTotal + amb
            }

            let lit = baseColor * (lightSum * exposureGain)
            return simd_clamp(lit, .zero, SIMD3(repeating: 1))
        }
    }

    // MARK: - 3D Camera Projector & Near-Plane Clipper

    private struct ProjectedTriangle {
        var p0: CGPoint
        var p1: CGPoint
        var p2: CGPoint
        var depth: Float
        var area: CGFloat
        var color: SIMD3<Float>
        var alpha: Float
    }

    private struct ProjectedEdge {
        var p0: CGPoint
        var p1: CGPoint
        var depth: Float
        var length: CGFloat
    }

    private struct Projector {
        let eye: SIMD3<Float>
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        let forward: SIMD3<Float>
        let isPerspective: Bool
        let focalScale: Float
        let nearZ: Float
        let halfWidth: CGFloat
        let halfHeight: CGFloat
        let boundsRect: CGRect

        init(
            pose: CameraRig.Pose,
            isPerspective: Bool,
            fovDegrees: Float,
            orthographicScale: Float,
            pageSize: CGSize
        ) {
            self.eye = pose.position
            self.right = pose.right
            self.up = pose.up
            self.forward = pose.forward
            self.isPerspective = isPerspective
            self.halfWidth = pageSize.width * 0.5
            self.halfHeight = pageSize.height * 0.5
            self.boundsRect = CGRect(x: -8, y: -8, width: pageSize.width + 16, height: pageSize.height + 16)

            if isPerspective {
                let tanHalf = max(1e-4, tan(max(10.0, min(120.0, fovDegrees)) * .pi / 360.0))
                self.focalScale = Float(pageSize.height * 0.5) / tanHalf
                self.nearZ = max(0.04, min(0.25, pose.distance * 0.005))
            } else {
                let ortho = max(0.01, orthographicScale)
                self.focalScale = Float(pageSize.height * 0.5) / ortho
                self.nearZ = -10_000.0
            }
        }

        @inline(__always)
        private func toCamera(_ world: SIMD3<Float>) -> SIMD3<Float> {
            let v = world - eye
            return SIMD3<Float>(
                simd_dot(v, right),
                simd_dot(v, up),
                simd_dot(v, forward)
            )
        }

        @inline(__always)
        private func toScreen(_ cam: SIMD3<Float>) -> CGPoint {
            if isPerspective {
                let invZ = focalScale / max(nearZ, cam.z)
                return CGPoint(
                    x: halfWidth + CGFloat(cam.x * invZ),
                    y: halfHeight + CGFloat(cam.y * invZ)
                )
            } else {
                return CGPoint(
                    x: halfWidth + CGFloat(cam.x * focalScale),
                    y: halfHeight + CGFloat(cam.y * focalScale)
                )
            }
        }

        func projectSegment(_ w0: SIMD3<Float>, _ w1: SIMD3<Float>, depthBias: Float) -> ProjectedEdge? {
            var c0 = toCamera(w0)
            var c1 = toCamera(w1)

            if isPerspective {
                if c0.z < nearZ && c1.z < nearZ { return nil }
                if c0.z < nearZ {
                    let t = (nearZ - c0.z) / max(1e-6, c1.z - c0.z)
                    c0 = c0 + (c1 - c0) * t
                } else if c1.z < nearZ {
                    let t = (nearZ - c1.z) / max(1e-6, c0.z - c1.z)
                    c1 = c1 + (c0 - c1) * t
                }
            }

            let s0 = toScreen(c0)
            let s1 = toScreen(c1)
            let minX = min(s0.x, s1.x), maxX = max(s0.x, s1.x)
            let minY = min(s0.y, s1.y), maxY = max(s0.y, s1.y)
            if maxX < boundsRect.minX || minX > boundsRect.maxX || maxY < boundsRect.minY || minY > boundsRect.maxY {
                return nil
            }
            let len = hypot(s1.x - s0.x, s1.y - s0.y)
            let depth = ((c0.z + c1.z) * 0.5) - depthBias
            return ProjectedEdge(p0: s0, p1: s1, depth: depth, length: len)
        }

        func projectTriangle(_ w0: SIMD3<Float>, _ w1: SIMD3<Float>, _ w2: SIMD3<Float>) -> [(CGPoint, CGPoint, CGPoint, Float, CGFloat)] {
            let c0 = toCamera(w0), c1 = toCamera(w1), c2 = toCamera(w2)
            let verts = clipPolygonAgainstNearPlane([c0, c1, c2])
            guard verts.count >= 3 else { return [] }

            var out: [(CGPoint, CGPoint, CGPoint, Float, CGFloat)] = []
            let p0 = toScreen(verts[0])
            for i in 1..<(verts.count - 1) {
                let p1 = toScreen(verts[i])
                let p2 = toScreen(verts[i + 1])
                let minX = min(p0.x, min(p1.x, p2.x)), maxX = max(p0.x, max(p1.x, p2.x))
                let minY = min(p0.y, min(p1.y, p2.y)), maxY = max(p0.y, max(p1.y, p2.y))
                if maxX < boundsRect.minX || minX > boundsRect.maxX || maxY < boundsRect.minY || minY > boundsRect.maxY {
                    continue
                }
                let area = abs((p1.x - p0.x) * (p2.y - p0.y) - (p2.x - p0.x) * (p1.y - p0.y)) * 0.5
                guard area > 0.01 else { continue }
                let depth = (verts[0].z + verts[i].z + verts[i + 1].z) * (1.0 / 3.0)
                out.append((p0, p1, p2, depth, area))
            }
            return out
        }

        private func clipPolygonAgainstNearPlane(_ polygon: [SIMD3<Float>]) -> [SIMD3<Float>] {
            guard isPerspective else { return polygon }
            var output: [SIMD3<Float>] = []
            guard var prev = polygon.last else { return [] }
            var prevInside = prev.z >= nearZ

            for curr in polygon {
                let currInside = curr.z >= nearZ
                if currInside != prevInside {
                    let t = (nearZ - prev.z) / (curr.z - prev.z)
                    output.append(prev + (curr - prev) * t)
                }
                if currInside {
                    output.append(curr)
                }
                prev = curr
                prevInside = currInside
            }
            return output
        }
    }
}
