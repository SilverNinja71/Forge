import Testing
import Foundation
import simd
@testable import ForgeCore

func rectRegion(_ lo: Vec2, _ hi: Vec2) -> ProfileRegion {
    var s = Sketch2D()
    s.addRectangle(lo, hi)
    return s.regions()[0]
}

func box(_ lo: Vec3, _ hi: Vec3, feature: Int = 1) throws -> Solid {
    let frame = Frame3(origin: Vec3(0, 0, lo.z), x: Vec3(1, 0, 0), y: Vec3(0, 1, 0))
    return try ExtrudeOp.solid(regions: [rectRegion(Vec2(lo.x, lo.y), Vec2(hi.x, hi.y))], frame: frame,
                               rings: [.init(height: 0), .init(height: hi.z - lo.z)], feature: feature)
}

func cylinder(center: Vec2, radius: Double, z0: Double, z1: Double, feature: Int = 2) throws -> Solid {
    var s = Sketch2D()
    s.addCircle(center: center, radius: radius)
    let frame = Frame3(origin: Vec3(0, 0, z0), x: Vec3(1, 0, 0), y: Vec3(0, 1, 0))
    return try ExtrudeOp.solid(regions: s.regions(), frame: frame, rings: [.init(height: 0), .init(height: z1 - z0)], feature: feature)
}

func close(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

@Suite("Solid modelling")
struct SolidTests {
    @Test func boxVolumeAreaAndCentre() throws {
        let b = try box(Vec3(0, 0, 0), Vec3(40, 30, 10))
        let m = b.massProperties()
        #expect(b.isClosed)
        #expect(close(m.volume, 12000))
        let area: Double = 2 * (1200 + 400 + 300)
        #expect(close(m.surfaceArea, area))
        #expect(simd_length(m.centerOfMass - Vec3(20, 15, 5)) < 1e-9)
        // Textbook inertia of a box about its centre, per unit density: V·(b² + c²)/12.
        let v = 12000.0
        #expect(close(m.inertia[0], v * 1000 / 12, 1e-3))
        #expect(close(m.inertia[1], v * 1700 / 12, 1e-3))
        #expect(close(m.inertia[2], v * 2500 / 12, 1e-3))
        #expect(abs(m.inertia[3]) < 1e-3)
    }

    @Test func cylinderIsCloseToTheTrueVolume() throws {
        let c = try cylinder(center: Vec2(0, 0), radius: 10, z0: 0, z1: 20)
        #expect(c.isClosed)
        let v = c.massProperties().volume
        let exact = Double.pi * 100 * 20
        #expect(abs(v - exact) / exact < 0.005)
    }

    @Test func unionSubtractIntersectVolumes() throws {
        let a = try box(Vec3(0, 0, 0), Vec3(20, 20, 20), feature: 1)
        let b = try box(Vec3(10, 10, 10), Vec3(30, 30, 30), feature: 2)
        let u = CSG.combine(a, b, .union), s = CSG.combine(a, b, .subtract), i = CSG.combine(a, b, .intersect)
        #expect(u.isClosed)
        #expect(s.isClosed)
        #expect(i.isClosed)
        #expect(close(u.massProperties().volume, 8000 + 8000 - 1000))
        #expect(close(s.massProperties().volume, 8000 - 1000))
        #expect(close(i.massProperties().volume, 1000))
    }

    @Test func touchingAndIdenticalBodies() throws {
        let a = try box(Vec3(0, 0, 0), Vec3(10, 10, 10), feature: 1)
        let b = try box(Vec3(10, 0, 0), Vec3(20, 10, 10), feature: 2)
        let u = CSG.combine(a, b, .union)
        #expect(u.isClosed)
        #expect(close(u.massProperties().volume, 2000))
        let area: Double = 2 * (200 + 200 + 100)
        #expect(close(u.massProperties().surfaceArea, area))
        let same = try box(Vec3(0, 0, 0), Vec3(10, 10, 10), feature: 3)
        #expect(close(CSG.combine(a, same, .union).massProperties().volume, 1000))
        #expect(close(CSG.combine(a, same, .intersect).massProperties().volume, 1000))
        #expect(CSG.combine(a, same, .subtract).isEmpty)
        // Far apart: subtract leaves the first body, intersect is empty.
        let far = try box(Vec3(100, 100, 100), Vec3(110, 110, 110), feature: 4)
        #expect(close(CSG.combine(a, far, .subtract).massProperties().volume, 1000))
        #expect(CSG.combine(a, far, .intersect).isEmpty)
    }

    @Test func holeThroughAPlateStaysWatertight() throws {
        let plate = try box(Vec3(0, 0, 0), Vec3(40, 30, 5))
        let peg = try cylinder(center: Vec2(20, 15), radius: 6, z0: -5, z1: 15)
        let holed = CSG.combine(plate, peg, .subtract)
        #expect(holed.isClosed)
        let m = holed.massProperties()
        let expected: Double = 6000 - Double.pi * 180
        #expect(abs(m.volume - expected) / expected < 0.005)
    }

    @Test func facesKeepTheirNamesThroughBooleans() throws {
        let plate = try box(Vec3(0, 0, 0), Vec3(40, 30, 5), feature: 1)
        let peg = try cylinder(center: Vec2(20, 15), radius: 6, z0: -5, z1: 15, feature: 2)
        let holed = CSG.combine(plate, peg, .subtract)
        #expect(holed.tags.contains(FaceTag(feature: 1, role: .endCap)))
        #expect(holed.tags.contains(where: { $0.feature == 2 && $0.role == .side }))
        // The peg's caps were outside the plate, so they must be gone.
        #expect(!holed.tags.contains(FaceTag(feature: 2, role: .endCap)))
        // The top keeps one face with a hole, not many fragments.
        let top = holed.faces(tagged: FaceTag(feature: 1, role: .endCap))
        #expect(top.count == 1)
        #expect(top[0].loops.count == 2)
    }

    @Test func cuttingInTwoMakesTwoBodies() throws {
        let bar = try box(Vec3(0, 0, 0), Vec3(30, 10, 10))
        let cut = try box(Vec3(10, -5, -5), Vec3(20, 15, 15), feature: 2)
        let pieces = CSG.combine(bar, cut, .subtract).separated()
        #expect(pieces.count == 2)
        #expect(pieces.allSatisfy { $0.isClosed && close($0.massProperties().volume, 1000) })
    }

    @Test func internalCavityStaysWithItsBody() throws {
        let outer = try box(Vec3(0, 0, 0), Vec3(20, 20, 20))
        let inner = try box(Vec3(5, 5, 5), Vec3(15, 15, 15), feature: 2)
        let hollow = CSG.combine(outer, inner, .subtract)
        let pieces = hollow.separated()
        #expect(pieces.count == 1)
        #expect(close(pieces[0].massProperties().volume, 8000 - 1000))
        #expect(pieces[0].contains(Vec3(2, 2, 2)))
        #expect(!pieces[0].contains(Vec3(10, 10, 10)))
    }

    @Test func draftTapersTheWalls() throws {
        // A 20×20 base shrinking by 1 mm on every side over 10 mm is a frustum.
        let region = rectRegion(Vec2(0, 0), Vec2(20, 20))
        let s = try ExtrudeOp.solid(regions: [region], frame: .xy, rings: [.init(height: 0), .init(height: 10, offset: 1)], feature: 1)
        #expect(s.isClosed)
        let expected = 10.0 / 3 * (400 + 324 + (400 * 324).squareRoot())
        #expect(close(s.massProperties().volume, expected, 1e-6))
    }

    @Test func revolveMakesASolidOfRevolution() throws {
        // A rectangle from r=10 to r=20, height 5, spun around Y: a ring. V = π(R²-r²)h.
        var sk = Sketch2D()
        sk.addRectangle(Vec2(10, 0), Vec2(20, 5))
        let s = try RevolveOp.solid(regions: sk.regions(), frame: .xy, axisA: Vec2(0, 0), axisB: Vec2(0, 1), angle: 2 * .pi, feature: 1)
        #expect(s.isClosed)
        let exact = Double.pi * (400 - 100) * 5
        let v = s.massProperties().volume
        #expect(abs(v - exact) / exact < 0.01)
    }

    @Test func partialRevolveAndProfileTouchingTheAxis() throws {
        var sk = Sketch2D()
        sk.addRectangle(Vec2(0, 0), Vec2(10, 5))
        let half = try RevolveOp.solid(regions: sk.regions(), frame: .xy, axisA: .zero, axisB: Vec2(0, 1), angle: .pi, feature: 1)
        #expect(half.isClosed)
        let exact = Double.pi * 100 * 5 / 2
        #expect(abs(half.massProperties().volume - exact) / exact < 0.01)
        #expect(half.tags.contains(FaceTag(feature: 1, role: .startCap)))
    }

    @Test func revolveRejectsCrossingTheAxis() {
        var sk = Sketch2D()
        sk.addRectangle(Vec2(-5, 0), Vec2(10, 5))
        #expect(throws: FeatureError.self) {
            _ = try RevolveOp.solid(regions: sk.regions(), frame: .xy, axisA: .zero, axisB: Vec2(0, 1), angle: 2 * .pi, feature: 1)
        }
    }

    func topEdge(_ s: Solid, _ line: Int) -> EdgeRef {
        EdgeRef(a: FaceTag(feature: 1, role: .side, entity: line), b: FaceTag(feature: 1, role: .endCap))
    }

    @Test func filletOneBoxEdgeRemovesTheExactVolume() throws {
        var sk = Sketch2D()
        let lines = sk.addRectangle(Vec2(0, 0), Vec2(40, 30))
        let b = try ExtrudeOp.solid(regions: sk.regions(), frame: .xy, rings: [.init(height: 0), .init(height: 10)], feature: 1)
        let r = 3.0
        let f = try FilletOp.apply(to: b, refs: [topEdge(b, lines[2])], shape: .fillet(radius: r), feature: 2)
        #expect(f.isClosed)
        // Removed: a square corner minus a quarter circle, along the 40 mm edge. The mesh follows the arc to
        // within 0.02 mm, and that band of error over the fillet's area bounds the difference.
        let removed = (r * r - Double.pi * r * r / 4) * 40
        let v = f.massProperties().volume
        #expect(abs(v - (12000 - removed)) < 0.02 * (Double.pi / 2 * r) * 40)
        #expect(f.tags.contains { $0.role == .fillet })
    }

    @Test func filletAllFourTopEdges() throws {
        var sk = Sketch2D()
        let lines = sk.addRectangle(Vec2(0, 0), Vec2(40, 30))
        let b = try ExtrudeOp.solid(regions: sk.regions(), frame: .xy, rings: [.init(height: 0), .init(height: 10)], feature: 1)
        let f = try FilletOp.apply(to: b, refs: lines.map { topEdge(b, $0) }, shape: .fillet(radius: 2), feature: 2)
        #expect(f.isClosed)
        // Perimeter × (corner square minus quarter circle), give or take the mesh and the corners.
        let removed: Double = 140 * (4 - Double.pi)
        #expect(abs(f.massProperties().volume - (12000 - removed)) < 5)
    }

    @Test func filletTheRimOfACylinder() throws {
        var sk = Sketch2D()
        let circle = sk.addCircle(center: .zero, radius: 15)
        let c = try ExtrudeOp.solid(regions: sk.regions(), frame: .xy, rings: [.init(height: 0), .init(height: 20)], feature: 1)
        let f = try FilletOp.apply(to: c, refs: [topEdge(c, circle)], shape: .fillet(radius: 2), feature: 2)
        #expect(f.isClosed)
        // Pappus: V removed = (corner area) × 2π × (centroid radius). Corner area = r²(1-π/4), centroid at r(1-0.2234) from the corner circle.
        let r = 2.0, R = 15.0
        let cornerArea = r * r * (1 - Double.pi / 4)
        let centroid = R - r * 0.2234
        let removed = cornerArea * 2 * .pi * centroid
        let original = c.massProperties().volume
        #expect(abs(f.massProperties().volume - (original - removed)) < 4)
    }

    @Test func filletAConcaveEdgeAddsMaterial() throws {
        // An L-shaped bar. The inner corner runs along Z.
        var sk = Sketch2D()
        let pts = [Vec2(0, 0), Vec2(30, 0), Vec2(30, 10), Vec2(10, 10), Vec2(10, 30), Vec2(0, 30)]
        let ids = pts.map { sk.addPoint($0) }
        var lines: [Int] = []
        for i in ids.indices { lines.append(sk.addLine(from: ids[i], to: ids[(i + 1) % ids.count])) }
        let l = try ExtrudeOp.solid(regions: sk.regions(), frame: .xy, rings: [.init(height: 0), .init(height: 5)], feature: 1)
        let before = l.massProperties().volume
        let ref = EdgeRef(a: FaceTag(feature: 1, role: .side, entity: lines[2]), b: FaceTag(feature: 1, role: .side, entity: lines[3]))
        let f = try FilletOp.apply(to: l, refs: [ref], shape: .fillet(radius: 4), feature: 2)
        #expect(f.isClosed)
        let added = (16 - Double.pi * 16 / 4) * 5
        // The mesh follows the arc to within 0.02 mm over the fillet's area (6.3 × 5 mm).
        #expect(abs(f.massProperties().volume - (before + added)) < 0.02 * 2 * Double.pi * 5)
    }

    @Test func chamfersRemoveTheExactVolume() throws {
        var sk = Sketch2D()
        let lines = sk.addRectangle(Vec2(0, 0), Vec2(40, 30))
        let b = try ExtrudeOp.solid(regions: sk.regions(), frame: .xy, rings: [.init(height: 0), .init(height: 10)], feature: 1)
        let equal = try FilletOp.apply(to: b, refs: [topEdge(b, lines[2])], shape: .chamfer(d1: 2, d2: 2), feature: 2)
        #expect(equal.isClosed)
        #expect(close(equal.massProperties().volume, 11920, 1e-6))
        let two = try FilletOp.apply(to: b, refs: [topEdge(b, lines[2])], shape: .chamfer(d1: 2, d2: 3), feature: 2)
        #expect(close(two.massProperties().volume, 11880, 1e-6))
        let angled = try FilletOp.apply(to: b, refs: [topEdge(b, lines[2])], shape: .chamferAngle(distance: 2, angle: .pi / 4), feature: 2)
        #expect(close(angled.massProperties().volume, 11920, 1e-6))
    }

    @Test func tooLargeFilletIsRefusedWithAReason() throws {
        var sk = Sketch2D()
        let lines = sk.addRectangle(Vec2(0, 0), Vec2(40, 30))
        let b = try ExtrudeOp.solid(regions: sk.regions(), frame: .xy, rings: [.init(height: 0), .init(height: 10)], feature: 1)
        #expect(throws: FeatureError.self) {
            _ = try FilletOp.apply(to: b, refs: [topEdge(b, lines[2])], shape: .fillet(radius: 50), feature: 2)
        }
    }

    @Test func shellLeavesWallsOfTheRightThickness() throws {
        let b = try box(Vec3(0, 0, 0), Vec3(40, 30, 20))
        let s = try ShellOp.apply(to: b, removing: [FaceTag(feature: 1, role: .endCap)], thickness: 2, feature: 2)
        #expect(s.isClosed)
        let inner = 36.0 * 26.0 * 18.0
        #expect(close(s.massProperties().volume, 24000 - inner, 1e-3))
        #expect(s.contains(Vec3(1, 15, 10)))
        #expect(!s.contains(Vec3(20, 15, 19)))
    }

    @Test func shellOfACylinderWithANoOpenFaceMakesACavity() throws {
        let c = try cylinder(center: .zero, radius: 20, z0: 0, z1: 30, feature: 1)
        let s = try ShellOp.apply(to: c, removing: [], thickness: 3, feature: 2)
        #expect(s.isClosed)
        #expect(!s.contains(Vec3(0, 0, 15)))
        #expect(s.contains(Vec3(18.5, 0, 15)))
    }

    @Test func loftBetweenSquares() throws {
        let a: [Vec3] = [Vec3(0, 0, 0), Vec3(20, 0, 0), Vec3(20, 20, 0), Vec3(0, 20, 0)]
        let b: [Vec3] = [Vec3(5, 5, 10), Vec3(15, 5, 10), Vec3(15, 15, 10), Vec3(5, 15, 10)]
        let s = try LoftSweepOp.loft(loops: [a, b], feature: 1)
        #expect(s.isClosed)
        let frustum = 10.0 / 3 * (400 + 100 + 200)
        #expect(abs(s.massProperties().volume - frustum) / frustum < 0.02)
    }

    @Test func sweepAlongAPath() throws {
        let square = [Vec2(-2, -2), Vec2(2, -2), Vec2(2, 2), Vec2(-2, 2)]
        let path = [Vec3(0, 0, 0), Vec3(0, 0, 10), Vec3(0, 0, 20)]
        let s = try LoftSweepOp.sweep(outline: square, frame: .xy, path: path, feature: 1)
        #expect(s.isClosed)
        #expect(close(s.massProperties().volume, 16 * 20, 1e-6))
    }

    @Test func minimumDistanceAndContainment() throws {
        let a = try box(Vec3(0, 0, 0), Vec3(10, 10, 10), feature: 1)
        let b = try box(Vec3(13, 4, 0), Vec3(20, 10, 10), feature: 2)
        #expect(close(a.minimumDistance(to: b).distance, 3))
        #expect(a.contains(Vec3(5, 5, 5)))
        #expect(!a.contains(Vec3(15, 5, 5)))
    }
}

@Suite("Picking and camera")
struct PickingTests {
    @Test func aPartSeenFromAboveOffersItsTopEdgeNotTheOneHiddenBehindIt() throws {
        // Looking straight down, the top and bottom edges of a box's side project onto the same pixels.
        var sk = Sketch2D()
        let lines = sk.addRectangle(Vec2(0, 0), Vec2(40, 30))
        let b = try ExtrudeOp.solid(regions: sk.regions(), frame: .xy, rings: [.init(height: 0), .init(height: 10)], feature: 1)
        var cam = CadCamera()
        cam.look(along: .xy)
        cam.target = Vec3(20, 15, 5)
        cam.viewHeight = 60
        let size = CGSize(width: 600, height: 600)
        let at = cam.project(Vec3(20, 0, 10), viewSize: size)
        let pick = CadPicker.pick(at, camera: cam, viewSize: size, bodies: [Body(id: 1, name: "b", solid: b)])
        let top = EdgeRef(a: FaceTag(feature: 1, role: .side, entity: lines[0]), b: FaceTag(feature: 1, role: .endCap))
        #expect(pick.edge.map { top.joins($0.a, $0.b) } == true)
    }

    @Test func aHiddenEdgeCantBePickedThroughAFace() throws {
        let b = try box(Vec3(0, 0, 0), Vec3(40, 30, 10))
        var cam = CadCamera()
        cam.target = b.bounds.center
        cam.viewHeight = 100
        let size = CGSize(width: 800, height: 600)
        // Middle of the top face: no edge anywhere near it.
        let at = cam.project(Vec3(20, 15, 10), viewSize: size)
        let pick = CadPicker.pick(at, camera: cam, viewSize: size, bodies: [Body(id: 1, name: "b", solid: b)])
        #expect(pick.edge == nil)
        #expect(pick.face == FaceTag(feature: 1, role: .endCap))
    }

    @Test func projectionAndRayAgree() {
        var cam = CadCamera()
        cam.viewHeight = 77
        let size = CGSize(width: 640, height: 480)
        let p = Vec3(3, -7, 11)
        let s = cam.project(p, viewSize: size)
        let ray = cam.ray(at: s, viewSize: size)
        let v = p - ray.origin
        #expect(simd_length(simd_cross(v, ray.direction)) < 1e-9)
    }

    @Test func filletASmallConcaveRingWithoutTurningItInsideOut() throws {
        // A neck joining a shoulder: a concave circular edge whose radius is close to the fillet's.
        var profile = Sketch2D()
        let pts = [Vec2(0, 0), Vec2(25, 0), Vec2(25, 40), Vec2(10, 60), Vec2(10, 80), Vec2(0, 80)]
        let ids = pts.map { profile.addPoint($0) }
        var lines: [Int] = []
        for i in ids.indices { lines.append(profile.addLine(from: ids[i], to: ids[(i + 1) % ids.count])) }
        let s = try RevolveOp.solid(regions: profile.regions(), frame: .xz, axisA: .zero, axisB: Vec2(0, 1), angle: 2 * .pi, feature: 1)
        let before = s.massProperties().volume
        let ref = EdgeRef(a: FaceTag(feature: 1, role: .side, entity: lines[2]), b: FaceTag(feature: 1, role: .side, entity: lines[3]))
        let f = try FilletOp.apply(to: s, refs: [ref], shape: .fillet(radius: 6), feature: 2)
        #expect(f.isClosed)
        // A sliver of about 0.42 mm² swept round a circle of radius 10 adds about 26 mm³.
        let added = f.massProperties().volume - before
        #expect(added > 10 && added < 45)
    }
}
