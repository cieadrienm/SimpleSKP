import Foundation
import simd
import SimpleSKPCore

/// A model that needs no SketchUp: `--snapshot` and `--self-test` without a file, and the tests.
enum SyntheticModel {
    /// A 1 m cube definition (12 triangles, 12 edges) placed twice: white at the origin on « Calque 0 », amber
    /// (instance material) at x = 1.5 m on « Décor »; one scene with a camera.
    static func cube() -> SKPModel {
        // Six faces: (normal, two in-face axes); corners in 0…1.
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0, 0, -1), SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 0, 0)),
            (SIMD3(0, 0, 1), SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
            (SIMD3(0, -1, 0), SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),
            (SIMD3(0, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)),
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            (SIMD3(1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
        ]
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(24); normals.reserveCapacity(24); indices.reserveCapacity(36)
        for (normal, origin, u, v) in faces {
            let base = UInt32(positions.count)
            positions += [origin, origin + u, origin + u + v, origin + v]
            normals += [normal, normal, normal, normal]
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        let corners = (0..<8).map { SIMD3<Float>(Float($0 & 1), Float($0 >> 1 & 1), Float($0 >> 2 & 1)) }
        let edgePairs = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
        let edges = edgePairs.flatMap { [corners[$0.0], corners[$0.1]] }

        let cube = SKPModel.Definition(
            name: "Cube",
            meshes: [SKPModel.Mesh(material: nil, layer: 0, positions: positions, normals: normals, indices: indices)],
            edges: [SKPModel.EdgeSet(layer: 0, positions: edges)]
        )
        var shifted = matrix_identity_float4x4
        shifted.columns.3 = SIMD4(1.5, 0, 0, 1)
        let root = SKPModel.Definition(name: "Modèle", children: [
            SKPModel.Instance(definition: 0, transform: matrix_identity_float4x4, layer: 0, isGroup: false, name: "Cube 1"),
            SKPModel.Instance(definition: 0, transform: shifted, layer: 1, isGroup: false, material: 0, name: "Cube 2"),
        ])
        let camera = SKPModel.Camera(position: SIMD3(4.5, -3.5, 3), target: SIMD3(1.25, 0.5, 0.5))
        let info = SKPFileInfo(
            url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Cube.skp"),
            fileSize: 0, version: "23.0.0", versionLabel: "SketchUp 2023", thumbnailPNG: nil
        )
        return SKPModel(
            root: root,
            definitions: [cube],
            materials: [SKPModel.Material(name: "Ambre", color: SIMD4(1, 0.706, 0.329, 1))],
            layers: [SKPModel.Layer(name: "Calque 0", isVisible: true), SKPModel.Layer(name: "Décor", isVisible: true)],
            scenes: [SKPModel.Scene(name: "Vue iso", camera: camera)],
            camera: camera,
            boundsMin: SIMD3(0, 0, 0),
            boundsMax: SIMD3(2.5, 1, 1),
            stats: SKPModel.Stats(faces: 12, triangles: 24, edges: 24, instances: 2, definitions: 1),
            fileInfo: info
        )
    }
}
