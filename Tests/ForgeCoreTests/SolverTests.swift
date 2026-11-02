import Testing
import Foundation
import simd
@testable import ForgeCore

private func dim(_ name: String, _ value: Double, _ expr: String? = nil) -> SketchDimension {
    SketchDimension(name: name, expression: expr ?? "\(value)mm", value: value)
}

/// 40×25 rectangle anchored at the origin by constraints alone.
private func dimensionedRectangle() -> (Sketch2D, [Int]) {
    var s = Sketch2D()
    let lines = s.addRectangle(Vec2(1, 2), Vec2(30, 18))
    let (corner, _) = s.endpoints(of: lines[0])!
    s.addConstraint(.coincident(p: corner, q: Sketch2D.originID))
    s.addConstraint(.distance(p: corner, q: s.endpoints(of: lines[0])!.b), dimension: dim("d1", 40))
    s.addConstraint(.distance(p: s.endpoints(of: lines[1])!.a, q: s.endpoints(of: lines[1])!.b), dimension: dim("d2", 25))
    return (s, lines)
}

@Suite("Expressions")
struct ExpressionTests {
    func eval(_ text: String, _ vars: [String: Quantity] = [:], inch: Bool = false) throws -> Quantity {
        try ExpressionEvaluator(defaultLength: inch ? 25.4 : 1) { vars[$0] }.evaluate(text)
    }

    @Test func theBriefsExample() throws {
        let q = try eval("d1 * 2 + 5mm", ["d1": .length(10)])
        #expect(q == .length(25))
    }

    @Test func unitsConvert() throws {
        #expect(try eval("1in").value == 25.4)
        #expect(try eval("2cm + 3mm").value == 23)
        #expect(abs(try eval("90deg").value - .pi / 2) < 1e-15)
        #expect(try eval("1m").lengthPower == 1)
    }

    @Test func areasAndRootsKeepUnits() throws {
        let area = try eval("3mm * 4mm")
        #expect(area == Quantity(12, lengthPower: 2))
        let root = try eval("sqrt(9mm * 4mm)")
        #expect(root == .length(6))
    }

    @Test func precedenceAndFunctions() throws {
        #expect(try eval("2 + 3 * 4").value == 14)
        #expect(try eval("(2 + 3) * 4").value == 20)
        #expect(try eval("2 ^ 3 ^ 2").value == 512)
        #expect(try eval("-2 ^ 2").value == 4)
        #expect(try eval("max(1, 2, 3) + min(4, 5)").value == 7)
        #expect(abs(try eval("sin(pi / 2)").value - 1) < 1e-15)
    }

    @Test func bareNumberUsesDocumentUnit() throws {
        #expect(try ExpressionEvaluator(defaultLength: 25.4).length("2") == 50.8)
        #expect(try ExpressionEvaluator(defaultLength: 25.4).length("1in + 1") == 50.8)
        #expect(abs(try ExpressionEvaluator().angle("90") - .pi / 2) < 1e-15)
        #expect(abs(try ExpressionEvaluator().angle("1rad") - 1) < 1e-15)
    }

    @Test func badFormulasExplainThemselves() {
        #expect(throws: ExpressionError.self) { try eval("2 +") }
        #expect(throws: ExpressionError.self) { try eval("nope + 1") }
        #expect(throws: ExpressionError.self) { try eval("3mm + 4mm * 2mm") }
        #expect(throws: ExpressionError.self) { try eval("1 / 0") }
        #expect(throws: ExpressionError.self) { try eval("5parsec") }
    }

    @Test func referencesSkipUnitsAndFunctions() {
        #expect(ExpressionEvaluator.references("d1 * 2 + 5mm") == ["d1"])
        #expect(ExpressionEvaluator.references("sin(a) + b * pi + 2in") == ["a", "b"])
    }

    @Test func parametersResolveInDependencyOrder() {
        let (values, errors) = ParameterSolver.evaluate([("c", "b * 2"), ("b", "a + 1mm"), ("a", "10mm")])
        #expect(errors.isEmpty)
        #expect(values["c"] == .length(22))
    }

    @Test func parameterCyclesAreReported() {
        let (_, errors) = ParameterSolver.evaluate([("a", "b"), ("b", "a")])
        #expect(errors["a"] != nil)
        #expect(errors["b"] != nil)
    }
}

@Suite("Constraint solver")
struct SolverTests {
    @Test func freeSketchHasOneDOFPerCoordinate() {
        var s = Sketch2D()
        s.addLine(Vec2(0, 0), Vec2(10, 3))
        let r = ConstraintSolver.solve(&s)
        #expect(r.degreesOfFreedom == 4)
        #expect(r.status == .underConstrained)
    }

    @Test func rectangleBecomesFullyConstrainedStepByStep() {
        var s = Sketch2D()
        let lines = s.addRectangle(Vec2(1, 2), Vec2(30, 18))
        // Four corners (8 unknowns) with 4 line joins already shared; H/V removes 4 → 4 left: position + size.
        #expect(ConstraintSolver.solve(&s).degreesOfFreedom == 4)
        let (corner, b) = s.endpoints(of: lines[0])!
        s.addConstraint(.coincident(p: corner, q: Sketch2D.originID))
        #expect(ConstraintSolver.solve(&s).degreesOfFreedom == 2)
        s.addConstraint(.distance(p: corner, q: b), dimension: dim("d1", 40))
        #expect(ConstraintSolver.solve(&s).degreesOfFreedom == 1)
        let (c, d) = s.endpoints(of: lines[1])!
        s.addConstraint(.distance(p: c, q: d), dimension: dim("d2", 25))
        let r = ConstraintSolver.solve(&s)
        #expect(r.status == .fullyConstrained)
        #expect(r.degreesOfFreedom == 0)
        #expect(r.freePoints.isEmpty)
        #expect(abs(s.position(s.endpoints(of: lines[2])!.a).x - 40) < 1e-9)
        #expect(abs(s.position(s.endpoints(of: lines[2])!.a).y - 25) < 1e-9)
    }

    @Test func reachesSubMicronAccuracy() {
        var (s, lines) = dimensionedRectangle()
        let r = ConstraintSolver.solve(&s)
        #expect(r.residual < 1e-9)  // 0.000000001 mm; a micron is 0.001 mm
        let (a, b) = s.endpoints(of: lines[0])!
        #expect(abs(simd_length(s.position(a) - s.position(b)) - 40) < 1e-9)
    }

    @Test func redundantConstraintTurnsTheSketchRed() {
        var (s, lines) = dimensionedRectangle()
        ConstraintSolver.solve(&s)
        // The bottom is already horizontal; saying so twice adds nothing.
        let extra = s.addConstraint(.parallel(l1: lines[0], l2: lines[2]))
        let r = ConstraintSolver.solve(&s)
        #expect(r.status == .overConstrained)
        #expect(!r.conflicting.isEmpty)
        s.removeConstraint(extra)
        #expect(ConstraintSolver.solve(&s).status == .fullyConstrained)
    }

    @Test func contradictoryDimensionsAreNamed() {
        var (s, lines) = dimensionedRectangle()
        ConstraintSolver.solve(&s)
        let (a, b) = s.endpoints(of: lines[0])!
        let bad = s.addConstraint(.distance(p: a, q: b), dimension: dim("d3", 55))
        let r = ConstraintSolver.solve(&s)
        #expect(r.status == .overConstrained)
        #expect(!r.converged)
        #expect(r.conflicting.contains(bad) || !r.conflicting.isEmpty)
    }

    @Test func perLineGeometricConstraints() {
        var s = Sketch2D()
        let a = s.addLine(Vec2(0, 0), Vec2(10, 1))
        let b = s.addLine(Vec2(0, 5), Vec2(9, 9))
        s.addConstraint(.parallel(l1: a, l2: b))
        #expect(ConstraintSolver.solve(&s).converged)
        func dir(_ l: Int) -> Vec2 {
            let (p, q) = s.endpoints(of: l)!
            return simd_normalize(s.position(q) - s.position(p))
        }
        #expect(abs(dir(a).cross(dir(b))) < 1e-9)
        s.removeConstraint(s.constraints[0].id)
        s.addConstraint(.perpendicular(l1: a, l2: b))
        #expect(ConstraintSolver.solve(&s).converged)
        #expect(abs(dir(a).dot(dir(b))) < 1e-9)
    }

    @Test func angleDimension() {
        var s = Sketch2D()
        let a = s.addLine(Vec2(0, 0), Vec2(10, 0))
        let b = s.addLine(Vec2(0, 0), Vec2(5, 8))
        s.addConstraint(.angle(l1: a, l2: b), dimension: dim("a1", .pi / 6, "30deg"))
        #expect(ConstraintSolver.solve(&s).converged)
        let (p, q) = s.endpoints(of: a)!, (u, v) = s.endpoints(of: b)!
        let da = s.position(q) - s.position(p), db = s.position(v) - s.position(u)
        #expect(abs(atan2(da.cross(db), da.dot(db)) - .pi / 6) < 1e-9)
    }

    @Test func tangentLineAndCircle() {
        var s = Sketch2D()
        let c = s.addCircle(center: Vec2(0, 0), radius: 10)
        let l = s.addLine(Vec2(-20, 12), Vec2(20, 13))
        s.addTangent(line: l, curve: c)
        #expect(ConstraintSolver.solve(&s).converged)
        let (p, q) = s.endpoints(of: l)!
        let a = s.position(p), d = s.position(q) - a
        let dist = abs(d.cross(s.position(s.center(of: c)!) - a)) / d.length
        #expect(abs(dist - s.radius(of: c)!) < 1e-9)
    }

    @Test func tangentCirclesInternalAndExternal() {
        var s = Sketch2D()
        let a = s.addCircle(center: Vec2(0, 0), radius: 10)
        let b = s.addCircle(center: Vec2(25, 0), radius: 10)
        s.addTangentCurves(a, b)
        #expect(ConstraintSolver.solve(&s).converged)
        let sep = simd_length(s.position(s.center(of: a)!) - s.position(s.center(of: b)!))
        #expect(abs(sep - (s.radius(of: a)! + s.radius(of: b)!)) < 1e-9)

        var t = Sketch2D()
        let big = t.addCircle(center: Vec2(0, 0), radius: 20)
        let small = t.addCircle(center: Vec2(3, 0), radius: 8)
        t.addTangentCurves(big, small)
        #expect(ConstraintSolver.solve(&t).converged)
        let inner = simd_length(t.position(t.center(of: big)!) - t.position(t.center(of: small)!))
        #expect(abs(inner - abs(t.radius(of: big)! - t.radius(of: small)!)) < 1e-9)
    }

    @Test func curvatureIsTangentPlusEqualRadius() {
        var s = Sketch2D()
        let a = s.addCircle(center: Vec2(0, 0), radius: 10)
        let b = s.addCircle(center: Vec2(25, 0), radius: 14)
        s.addTangentCurves(a, b, curvature: true)
        #expect(ConstraintSolver.solve(&s).converged)
        #expect(abs(s.radius(of: a)! - s.radius(of: b)!) < 1e-9)
    }

    @Test func symmetryMidpointCollinearConcentricEqual() {
        var s = Sketch2D()
        let axis = s.addLine(Vec2(0, -10), Vec2(0, 10))
        let ends = s.endpoints(of: axis)!
        s.addConstraint(.fixed(p: ends.a, at: Vec2(0, -10)))
        s.addConstraint(.fixed(p: ends.b, at: Vec2(0, 10)))
        let p = s.addPoint(Vec2(-7, 3)), q = s.addPoint(Vec2(5, 4))
        s.addConstraint(.symmetric(p: p, q: q, axis: axis))
        let edge = s.addLine(Vec2(1, 1), Vec2(9, 2))
        let m = s.addPoint(Vec2(5, 5))
        s.addConstraint(.midpoint(p: m, line: edge))
        let other = s.addLine(Vec2(0, 7), Vec2(3, 8))
        s.addConstraint(.collinear(l1: edge, l2: other))
        let c1 = s.addCircle(center: Vec2(30, 30), radius: 3), c2 = s.addCircle(center: Vec2(32, 31), radius: 6)
        s.addConstraint(.concentric(c1: c1, c2: c2))
        s.addConstraint(.equal(c1: c1, c2: c2))
        #expect(ConstraintSolver.solve(&s).converged)
        let pp = s.position(p), pq = s.position(q)
        #expect(abs(pp.x + pq.x) < 1e-9)
        #expect(abs(pp.y - pq.y) < 1e-9)
        let (ea, eb) = s.endpoints(of: edge)!
        #expect(simd_length(s.position(m) - (s.position(ea) + s.position(eb)) / 2) < 1e-9)
        let (oa, ob) = s.endpoints(of: other)!
        let d = s.position(eb) - s.position(ea)
        #expect(abs(d.cross(s.position(oa) - s.position(ea))) / d.length < 1e-9)
        #expect(abs(d.cross(s.position(ob) - s.position(ea))) / d.length < 1e-9)
        #expect(simd_length(s.position(s.center(of: c1)!) - s.position(s.center(of: c2)!)) < 1e-9)
        #expect(abs(s.radius(of: c1)! - s.radius(of: c2)!) < 1e-9)
    }

    @Test func radiusDiameterOffset() {
        var s = Sketch2D()
        let c = s.addCircle(center: Vec2(0, 0), radius: 3)
        s.addConstraint(.diameter(curve: c), dimension: dim("d1", 12))
        let a = s.addLine(Vec2(0, 0), Vec2(10, 0)), b = s.addLine(Vec2(0, 5), Vec2(10, 6))
        s.addConstraint(.offset(l1: a, l2: b), dimension: dim("d2", 8))
        #expect(ConstraintSolver.solve(&s).converged)
        #expect(abs(s.radius(of: c)! - 6) < 1e-9)
        let (p, q) = s.endpoints(of: b)!
        let (u, v) = s.endpoints(of: a)!
        let d = s.position(v) - s.position(u)
        #expect(abs(abs(d.cross(s.position(p) - s.position(u))) / d.length - 8) < 1e-9)
        #expect(abs(abs(d.cross(s.position(q) - s.position(u))) / d.length - 8) < 1e-9)
    }

    @Test func arcEndsStayOnTheCircle() {
        var s = Sketch2D()
        let arc = s.addArc(center: Vec2(0, 0), start: Vec2(10, 0), end: Vec2(0, 12))
        let r = ConstraintSolver.solve(&s)
        #expect(r.converged)
        guard case .arc(let c, let a, let b)? = s.curve(arc)?.geometry else { Issue.record("not an arc"); return }
        #expect(abs(simd_length(s.position(a) - s.position(c)) - simd_length(s.position(b) - s.position(c))) < 1e-9)
        #expect(r.degreesOfFreedom == 5)
    }

    @Test func draggingRespectsConstraintsAndFixedGeometryRefuses() {
        var (s, lines) = dimensionedRectangle()
        ConstraintSolver.solve(&s)
        let corner = s.endpoints(of: lines[2])!.a
        #expect(!ConstraintSolver.drag(&s, point: corner, to: Vec2(80, 80)))
        #expect(simd_length(s.position(corner) - Vec2(40, 25)) < 1e-9)

        var free = Sketch2D()
        let l = free.addLine(Vec2(0, 0), Vec2(10, 0))
        free.addConstraint(.horizontal(line: l))
        let (a, b) = free.endpoints(of: l)!
        #expect(ConstraintSolver.drag(&free, point: b, to: Vec2(20, 7)))
        #expect(simd_length(free.position(b) - Vec2(20, 7)) < 1e-12)
        #expect(abs(free.position(a).y - 7) < 1e-9)
    }

    @Test func perEntityFreedomIsReported() {
        var s = Sketch2D()
        let fixedLine = s.addLine(Vec2(0, 0), Vec2(10, 0))
        let (a, b) = s.endpoints(of: fixedLine)!
        s.addConstraint(.fixed(p: a, at: Vec2(0, 0)))
        s.addConstraint(.fixed(p: b, at: Vec2(10, 0)))
        let loose = s.addLine(Vec2(0, 5), Vec2(5, 5))
        let r = ConstraintSolver.solve(&s)
        #expect(!r.freePoints.contains(a))
        #expect(!r.freePoints.contains(b))
        #expect(r.freePoints.contains(s.endpoints(of: loose)!.a))
    }

    @Test func wildStartStillConverges() {
        var (s, _) = dimensionedRectangle()
        for i in s.points.indices where s.points[i].id != Sketch2D.originID {
            s.points[i].position += Vec2(Double(i) * 37, -Double(i) * 19)
        }
        #expect(ConstraintSolver.solve(&s).converged)
    }

    @Test func aHundredLineSketchSolvesQuickly() {
        var s = Sketch2D()
        var previous: Int?
        var firstPoint = 0
        for i in 0..<100 {
            let a = Double(i) * 2 * .pi / 100
            let p = s.addPoint(Vec2(cos(a) * 50, sin(a) * 50))
            if let prev = previous { s.addLine(from: prev, to: p) } else { firstPoint = p }
            previous = p
        }
        s.addLine(from: previous!, to: firstPoint)
        let lines = s.curves.map(\.id)
        for i in 1..<lines.count { s.addConstraint(.equal(c1: lines[0], c2: lines[i])) }
        let t0 = Date()
        let r = ConstraintSolver.solve(&s)
        #expect(r.converged)
        #expect(Date().timeIntervalSince(t0) < 5)
    }
}

@Suite("Sketch profiles")
struct ProfileTests {
    @Test func rectangleWithHole() {
        var s = Sketch2D()
        s.addRectangle(Vec2(0, 0), Vec2(40, 30))
        s.addCircle(center: Vec2(20, 15), radius: 5)
        let r = s.regions()
        #expect(r.count == 2)
        #expect(r[0].holes.count == 1)
        #expect(r[0].depth == 0)
        #expect(r[1].depth == 1)
        #expect(abs(r[0].area - (1200 - .pi * 25)) < 0.5)
    }

    @Test func crossingCurvesFormRegions() {
        var s = Sketch2D()
        s.addRectangle(Vec2(0, 0), Vec2(20, 20))
        s.addRectangle(Vec2(10, 10), Vec2(30, 30))
        let r = s.regions()
        #expect(r.count == 3)
        let total = r.reduce(0) { $0 + $1.area }
        #expect(abs(total - 700) < 1e-6)
    }

    @Test func openChainHasNoRegion() {
        var s = Sketch2D()
        s.addLine(Vec2(0, 0), Vec2(10, 0))
        s.addLine(Vec2(10, 0), Vec2(10, 10))
        #expect(s.regions().isEmpty)
    }

    @Test func constructionLinesAreIgnored() {
        var s = Sketch2D()
        s.addRectangle(Vec2(0, 0), Vec2(20, 20))
        s.addLine(Vec2(0, 0), Vec2(20, 20), construction: true)
        #expect(s.regions().count == 1)
    }

    @Test func lineAndArcSlot() {
        var s = Sketch2D()
        // A stadium shape: two lines and two half circles.
        s.addLine(Vec2(0, 0), Vec2(20, 0))
        s.addArc(center: Vec2(20, 5), start: Vec2(20, 0), end: Vec2(20, 10))
        s.addLine(Vec2(20, 10), Vec2(0, 10))
        s.addArc(center: Vec2(0, 5), start: Vec2(0, 10), end: Vec2(0, 0))
        let r = s.regions()
        #expect(r.count == 1)
        #expect(abs(r[0].area - (200 + .pi * 25)) < 0.5)
    }

    @Test func triangulationSurvivesARowOfHolesAtTheSameHeight() {
        // Holes in straight rows: each bridge lands exactly on the next hole's vertex, the awkward case.
        var s = Sketch2D()
        s.addRectangle(Vec2(0, 0), Vec2(120, 120))
        for i in 0..<6 {
            for j in 0..<6 {
                s.addCircle(center: Vec2(10 + Double(i) * 20, 10 + Double(j) * 20), radius: 3)
            }
        }
        let r = s.regions().first!
        #expect(r.holes.count == 36)
        let pts = r.allPoints, tris = r.triangles()
        var total = 0.0
        var i = 0
        while i < tris.count {
            let a = pts[Int(tris[i])], b = pts[Int(tris[i + 1])], c = pts[Int(tris[i + 2])]
            total += (b - a).cross(c - a) / 2
            i += 3
        }
        #expect(abs(total - r.area) < 1e-6)
    }

    @Test func triangulationCoversRegionExactly() {
        var s = Sketch2D()
        s.addRectangle(Vec2(0, 0), Vec2(40, 30))
        s.addCircle(center: Vec2(10, 15), radius: 5)
        s.addCircle(center: Vec2(30, 15), radius: 5)
        let r = s.regions().first!
        let pts = r.allPoints, tris = r.triangles()
        var total = 0.0
        var i = 0
        while i < tris.count {
            let a = pts[Int(tris[i])], b = pts[Int(tris[i + 1])], c = pts[Int(tris[i + 2])]
            let area = (b - a).cross(c - a) / 2
            #expect(area > 0)
            total += area
            i += 3
        }
        #expect(abs(total - r.area) < 1e-6)
    }
}
