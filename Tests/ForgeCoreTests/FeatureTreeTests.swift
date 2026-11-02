import Testing
import Foundation
import simd
@testable import ForgeCore

/// A plate whose size is driven by parameters: sketch → extrude → hole → fillet.
func bracketTree(width: String = "60mm") -> (FeatureTree, sketch: Int, extrude: Int, hole: Int, fillet: Int, topLine: Int) {
    var t = FeatureTree()
    t.parameters = [Parameter(name: "width", expression: width), Parameter(name: "depth", expression: "width / 2 + 10mm")]

    var s = Sketch2D()
    let lines = s.addRectangle(Vec2(1, 1), Vec2(50, 30))
    let (corner, b) = s.endpoints(of: lines[0])!
    s.addConstraint(.coincident(p: corner, q: Sketch2D.originID))
    s.addConstraint(.distance(p: corner, q: b), dimension: SketchDimension(name: "d1", expression: "width", value: 0))
    let (c, d) = s.endpoints(of: lines[1])!
    s.addConstraint(.distance(p: c, q: d), dimension: SketchDimension(name: "d2", expression: "depth", value: 0))
    let sketch = t.append(.sketch(SketchFeature(plane: .xy, sketch: s)))
    let extrude = t.append(.extrude(ExtrudeFeature(sketchID: sketch, extent: .blind("12mm"))))

    var h = Sketch2D()
    let circle = h.addCircle(center: Vec2(20, 15), radius: 5)
    let center = h.center(of: circle)!
    h.addConstraint(.distanceX(p: Sketch2D.originID, q: center), dimension: SketchDimension(name: "d3", expression: "d1 / 2", value: 0))
    h.addConstraint(.distanceY(p: Sketch2D.originID, q: center), dimension: SketchDimension(name: "d4", expression: "d2 / 2", value: 0))
    h.addConstraint(.diameter(curve: circle), dimension: SketchDimension(name: "d5", expression: "10mm", value: 0))
    let holeSketch = t.append(.sketch(SketchFeature(plane: .xy, sketch: h)))
    let hole = t.append(.extrude(ExtrudeFeature(sketchID: holeSketch, extent: .throughAll, operation: .cut)))

    let ref = EdgeRef(a: FaceTag(feature: extrude, role: .side, entity: lines[2]), b: FaceTag(feature: extrude, role: .endCap))
    let fillet = t.append(.fillet(FilletFeature(edges: [ref], radius: "3mm")))
    return (t, sketch, extrude, hole, fillet, lines[2])
}

@Suite("Feature tree")
struct FeatureTreeTests {
    @Test func theWholeHistoryRegenerates() {
        let (t, sketch, _, _, _, _) = bracketTree()
        let r = t.regenerate()
        #expect(r.errors.isEmpty)
        #expect(r.parameterErrors.isEmpty)
        #expect(r.final.bodies.count == 1)
        let solid = r.final.bodies[0].solid
        #expect(solid.isClosed)
        #expect(r.final.sketchSolutions[sketch]?.status == .fullyConstrained)
        // 60 × 40 × 12, minus a Ø10 hole, minus a little for the fillet.
        let plain: Double = 60 * 40 * 12 - Double.pi * 25 * 12
        let v = solid.massProperties().volume
        #expect(v < plain + 2)
        #expect(v > plain - 60 * 3)
        #expect(solid.tags.contains { $0.role == .fillet })
    }

    @Test func changingOneParameterCascadesThroughEverything() {
        var (t, _, _, _, _, _) = bracketTree()
        let before = t.regenerate().final.bodies[0].solid.bounds
        #expect(abs(before.size.x - 60) < 1e-6)
        #expect(abs(before.size.y - 40) < 1e-6)
        t.parameters[0].expression = "100mm"
        let r = t.regenerate()
        #expect(r.errors.isEmpty)
        let solid = r.final.bodies[0].solid
        // width drives d1; depth = width/2 + 10 drives d2.
        #expect(abs(solid.bounds.size.x - 100) < 1e-6)
        #expect(abs(solid.bounds.size.y - 60) < 1e-6)
        // The hole followed (it's at d1/2, d2/2): the centre is now empty, and the old centre is solid.
        #expect(!solid.contains(Vec3(50, 30, 6)))
        #expect(solid.contains(Vec3(30, 30, 6)))
        // The fillet found its edge again after the rebuild.
        #expect(solid.tags.contains { $0.role == .fillet })
    }

    @Test func expressionsCanUseUnitsAndOtherDimensions() {
        var (t, _, _, _, _, _) = bracketTree()
        t.parameters[0].expression = "2in + 5mm"
        let r = t.regenerate()
        #expect(abs(r.final.bodies[0].solid.bounds.size.x - 55.8) < 1e-6)
    }

    @Test func aBrokenFeatureIsFlaggedAndTheRestSurvives() {
        var (t, _, extrude, _, fillet, _) = bracketTree()
        if let i = t.features.firstIndex(where: { $0.id == extrude }), case .extrude(var e) = t.features[i].kind {
            e.extent = .blind("nonsense + 1")
            t.features[i].kind = .extrude(e)
        }
        let r = t.regenerate()
        #expect(r.errors[extrude] != nil)
        #expect(r.errors[fillet] != nil)
    }

    @Test func tooLargeFilletErrorDoesNotDestroyTheBody() {
        var (t, _, _, _, fillet, _) = bracketTree()
        if let i = t.features.firstIndex(where: { $0.id == fillet }), case .fillet(var f) = t.features[i].kind {
            f.radius = "500mm"
            t.features[i].kind = .fillet(f)
        }
        let r = t.regenerate()
        #expect(r.errors[fillet]?.contains("too large") == true)
        #expect(r.final.bodies.count == 1)
        #expect(!r.final.bodies[0].solid.tags.contains { $0.role == .fillet })
    }

    @Test func rollbackAndSuppress() {
        var (t, _, _, hole, fillet, _) = bracketTree()
        t.rollback = 2
        let plate = t.regenerate()
        #expect(abs(plate.final.bodies[0].solid.massProperties().volume - 28800) < 1e-6)
        t.rollback = nil
        if let i = t.features.firstIndex(where: { $0.id == hole }) { t.features[i].isSuppressed = true }
        if let i = t.features.firstIndex(where: { $0.id == fillet }) { t.features[i].isSuppressed = true }
        #expect(abs(t.regenerate().final.bodies[0].solid.massProperties().volume - 28800) < 1e-6)
    }

    @Test func incrementalRegenerationMatchesAFullOne() {
        var (t, _, _, _, fillet, _) = bracketTree()
        let first = t.regenerate()
        if let i = t.features.firstIndex(where: { $0.id == fillet }), case .fillet(var f) = t.features[i].kind {
            f.radius = "1.5mm"
            t.features[i].kind = .fillet(f)
        }
        let index = t.features.firstIndex { $0.id == fillet }!
        let fast = t.regenerate(reusing: first, firstChanged: index)
        let full = t.regenerate()
        #expect(abs(fast.final.bodies[0].solid.massProperties().volume - full.final.bodies[0].solid.massProperties().volume) < 1e-9)
    }

    @Test func extrudeModes() {
        func built(_ extent: ExtrudeExtent, _ op: BodyOperation = .newBody, flip: Bool = false, draft: String = "0deg") -> FeatureTree.Regeneration {
            var t = FeatureTree()
            var s = Sketch2D()
            s.addRectangle(Vec2(0, 0), Vec2(10, 10))
            let id = t.append(.sketch(SketchFeature(plane: .xy, sketch: s)))
            _ = t.append(.extrude(ExtrudeFeature(sketchID: id, extent: extent, operation: op, flip: flip, draft: draft)))
            return t.regenerate()
        }
        let up = built(.blind("5mm")).final.bodies[0].solid.bounds
        #expect(abs(up.hi.z - 5) < 1e-9)
        let down = built(.blind("5mm"), flip: true).final.bodies[0].solid.bounds
        #expect(abs(down.lo.z + 5) < 1e-9)
        let both = built(.symmetric("10mm")).final.bodies[0].solid.bounds
        #expect(abs(both.lo.z + 5) < 1e-9 && abs(both.hi.z - 5) < 1e-9)
        let drafted = built(.blind("5mm"), draft: "10deg").final.bodies[0].solid
        #expect(drafted.isClosed)
        #expect(drafted.massProperties().volume < 500)
        #expect(built(.throughAll).errors.count == 1)  // nothing to go through yet
        #expect(built(.blind("5mm"), .cut).errors.count == 1)  // nothing to cut yet
    }

    @Test func extrudeToAFace() {
        var t = FeatureTree()
        var a = Sketch2D()
        a.addRectangle(Vec2(0, 0), Vec2(30, 30))
        let s1 = t.append(.sketch(SketchFeature(plane: .xy, sketch: a)))
        let base = t.append(.extrude(ExtrudeFeature(sketchID: s1, extent: .blind("20mm"))))
        var b = Sketch2D()
        b.addRectangle(Vec2(50, 50), Vec2(60, 60))
        let s2 = t.append(.sketch(SketchFeature(plane: .xy, sketch: b)))
        _ = t.append(.extrude(ExtrudeFeature(sketchID: s2, extent: .toObject(FaceTag(feature: base, role: .endCap)))))
        let r = t.regenerate()
        #expect(r.errors.isEmpty)
        #expect(r.final.bodies.count == 2)
        #expect(abs(r.final.bodies[1].solid.bounds.hi.z - 20) < 1e-9)
    }

    @Test func joinCutIntersect() {
        var t = FeatureTree()
        var a = Sketch2D()
        a.addRectangle(Vec2(0, 0), Vec2(20, 20))
        let s1 = t.append(.sketch(SketchFeature(plane: .xy, sketch: a)))
        _ = t.append(.extrude(ExtrudeFeature(sketchID: s1, extent: .blind("10mm"))))
        var b = Sketch2D()
        b.addRectangle(Vec2(10, 10), Vec2(30, 30))
        let s2 = t.append(.sketch(SketchFeature(plane: .xy, sketch: b)))
        let e2 = t.append(.extrude(ExtrudeFeature(sketchID: s2, extent: .blind("10mm"), operation: .join)))
        let joined = t.regenerate()
        #expect(joined.final.bodies.count == 1)
        #expect(abs(joined.final.bodies[0].solid.massProperties().volume - 7000) < 1e-6)

        func set(_ op: BodyOperation) {
            let i = t.features.firstIndex { $0.id == e2 }!
            if case .extrude(var e) = t.features[i].kind {
                e.operation = op
                t.features[i].kind = .extrude(e)
            }
        }
        set(.cut)
        #expect(abs(t.regenerate().final.bodies[0].solid.massProperties().volume - 3000) < 1e-6)
        set(.intersect)
        #expect(abs(t.regenerate().final.bodies[0].solid.massProperties().volume - 1000) < 1e-6)
    }

    @Test func sketchOnAFaceFollowsTheFace() {
        var t = FeatureTree()
        t.parameters = [Parameter(name: "h", expression: "20mm")]
        var a = Sketch2D()
        a.addRectangle(Vec2(0, 0), Vec2(30, 30))
        let s1 = t.append(.sketch(SketchFeature(plane: .xy, sketch: a)))
        let base = t.append(.extrude(ExtrudeFeature(sketchID: s1, extent: .blind("h"))))
        var b = Sketch2D()
        b.addCircle(center: Vec2(15, 15), radius: 5)
        let s2 = t.append(.sketch(SketchFeature(plane: .face(FaceTag(feature: base, role: .endCap)), sketch: b)))
        _ = t.append(.extrude(ExtrudeFeature(sketchID: s2, extent: .blind("10mm"), operation: .join)))
        #expect(abs(t.regenerate().final.bodies[0].solid.bounds.hi.z - 30) < 1e-9)
        t.parameters[0].expression = "50mm"
        let r = t.regenerate()
        #expect(r.errors.isEmpty)
        #expect(abs(r.final.bodies[0].solid.bounds.hi.z - 60) < 1e-9)
    }

    @Test func revolveLoftSweepFromSketches() {
        var t = FeatureTree()
        var r = Sketch2D()
        r.addRectangle(Vec2(10, 0), Vec2(20, 5))
        let s = t.append(.sketch(SketchFeature(plane: .xz, sketch: r)))
        _ = t.append(.revolve(RevolveFeature(sketchID: s, axis: .sketchY)))
        var a = Sketch2D()
        a.addRectangle(Vec2(50, 0), Vec2(70, 20))
        let la = t.append(.sketch(SketchFeature(plane: .xy, sketch: a)))
        var b = Sketch2D()
        b.addCircle(center: Vec2(60, 10), radius: 5)
        let lb = t.append(.sketch(SketchFeature(plane: .offset(base: 0, distance: "30mm"), sketch: b)))
        _ = t.append(.loft(LoftFeature(sketchIDs: [la, lb])))
        var p = Sketch2D()
        p.addCircle(center: Vec2(0, 0), radius: 2)
        let prof = t.append(.sketch(SketchFeature(plane: .offset(base: 0, distance: "-60mm"), sketch: p)))
        var path = Sketch2D()
        path.addLine(Vec2(0, -60), Vec2(0, -30))
        path.addLine(Vec2(0, -30), Vec2(20, -10))
        let pathID = t.append(.sketch(SketchFeature(plane: .yz, sketch: path)))
        _ = t.append(.sweep(SweepFeature(profileSketchID: prof, pathSketchID: pathID)))
        let result = t.regenerate()
        #expect(result.errors.isEmpty, "\(result.errors)")
        #expect(result.final.bodies.count == 3)
        #expect(result.final.bodies.allSatisfy { $0.solid.isClosed })
    }

    @Test func shellFeature() {
        var t = FeatureTree()
        var a = Sketch2D()
        a.addRectangle(Vec2(0, 0), Vec2(40, 30))
        let s = t.append(.sketch(SketchFeature(plane: .xy, sketch: a)))
        let e = t.append(.extrude(ExtrudeFeature(sketchID: s, extent: .blind("20mm"))))
        _ = t.append(.shell(ShellFeature(openFaces: [FaceTag(feature: e, role: .endCap)], thickness: "2mm")))
        let r = t.regenerate()
        #expect(r.errors.isEmpty)
        #expect(abs(r.final.bodies[0].solid.massProperties().volume - (24000 - 36 * 26 * 18)) < 1e-3)
    }

    @Test func treeSurvivesJSON() throws {
        let (t, _, _, _, _, _) = bracketTree()
        let data = try JSONEncoder().encode(t)
        let back = try JSONDecoder().decode(FeatureTree.self, from: data)
        #expect(back == t)
        #expect(abs(back.regenerate().final.bodies[0].solid.massProperties().volume
            - t.regenerate().final.bodies[0].solid.massProperties().volume) < 1e-9)
    }
}
