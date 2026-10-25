import XCTest
import SimpleSKPCore

/// Manual probe: flattened triangle/vertex counts, layer sets and the most repeated definitions of `SIMPLESKP_BENCH`
/// (see FrameTimeHarness for the command). Skipped otherwise.
final class ModelStatsProbe: XCTestCase {
    func testStats() throws {
        guard let file = ProcessInfo.processInfo.environment["SIMPLESKP_BENCH"] else { throw XCTSkip("") }
        let model = try SKPReader.load(URL(fileURLWithPath: file))
        let tris = model.definitions.map { d in d.meshes.reduce(0) { $0 + $1.indices.count / 3 } }
        let verts = model.definitions.map { d in d.meshes.reduce(0) { $0 + $1.positions.count } }
        let segs = model.definitions.map { d in d.edges.reduce(0) { $0 + $1.positions.count / 2 } }
        var placements = [Int](repeating: 0, count: model.definitions.count)
        var flatTris = 0, flatVerts = 0, flatSegs = 0, uvVerts = 0
        var visTris = 0, visVerts = 0
        var sets = Set<[Int]>(), visSets = Set<[Int]>()
        func walk(_ d: SKPModel.Definition, _ layers: [Int]) {
            for m in d.meshes {
                let s = Array(Set(layers + [m.layer])).sorted(); sets.insert(s)
                flatTris += m.indices.count / 3; flatVerts += m.positions.count; if m.uvs != nil { uvVerts += m.positions.count }
                if s.allSatisfy({ model.layers[$0].isVisible }) { visTris += m.indices.count / 3; visVerts += m.positions.count; visSets.insert(s) }
            }
            for e in d.edges { flatSegs += e.positions.count / 2 }
            for c in d.children { placements[c.definition] += 1; walk(model.definitions[c.definition], Array(Set(layers + [c.layer])).sorted()) }
        }
        walk(model.root, [])
        print("PROBE layers \(model.layers.count) defs \(model.definitions.count) flat tris \(flatTris) verts \(flatVerts) uvVerts \(uvVerts) segs \(flatSegs) layerSets \(sets.count) visible: tris \(visTris) verts \(visVerts) sets \(visSets.count)")
        var big = 0, bigTris = 0
        for i in model.definitions.indices where tris[i] >= 50_000 && placements[i] >= 2 { big += 1; bigTris += tris[i] * placements[i] }
        print("PROBE big instanced defs \(big) flat tris \(bigTris)")
        let top = model.definitions.indices.sorted { tris[$0] * placements[$0] > tris[$1] * placements[$1] }.prefix(15)
        for i in top { print("PROBE \(model.definitions[i].name): tris \(tris[i]) verts \(verts[i]) segs \(segs[i]) x\(placements[i])") }
        print("PROBE materials \(model.materials.count) textured \(model.materials.filter { $0.textureURL != nil }.count)")
    }
}
