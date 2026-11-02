import Foundation
import simd

/// A named driving dimension: its formula and the value that formula last produced (mm or radians).
public struct SketchDimension: Codable, Equatable, Sendable {
    public var name: String
    public var expression: String
    public var value: Double

    public init(name: String, expression: String, value: Double) {
        self.name = name
        self.expression = expression
        self.value = value
    }
}

public struct SketchPoint: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var position: Vec2
    public var isConstruction = false
}

public struct SketchCurve: Codable, Equatable, Identifiable, Sendable {
    public enum Geometry: Codable, Equatable, Sendable {
        case line(a: Int, b: Int)
        case circle(center: Int, radius: Double)
        /// Runs counter-clockwise from `start` to `end`. The solver keeps both ends the same distance from the centre.
        case arc(center: Int, start: Int, end: Int)
    }

    public var id: Int
    public var geometry: Geometry
    /// Construction curves guide other geometry but never become part of a profile.
    public var isConstruction = false
}

public struct SketchConstraint: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        // Geometric. Numbers are point ids (p, q) or curve ids (line, curve, l1, l2, c1, c2).
        case coincident(p: Int, q: Int)
        case pointOnLine(p: Int, line: Int)
        case pointOnCurve(p: Int, curve: Int)
        case collinear(l1: Int, l2: Int)
        case concentric(c1: Int, c2: Int)
        case midpoint(p: Int, line: Int)
        case fixed(p: Int, at: Vec2)
        case parallel(l1: Int, l2: Int)
        case perpendicular(l1: Int, l2: Int)
        case horizontal(line: Int)
        case vertical(line: Int)
        case horizontalPoints(p: Int, q: Int)
        case verticalPoints(p: Int, q: Int)
        /// `side` is ±1: which side of the line the curve sits on.
        case tangent(line: Int, curve: Int, side: Double)
        case tangentCurves(c1: Int, c2: Int, isInternal: Bool)
        /// G2 continuity. Circles and arcs have constant curvature, so this is tangency plus equal radius.
        case curvature(c1: Int, c2: Int, isInternal: Bool)
        case symmetric(p: Int, q: Int, axis: Int)
        case equal(c1: Int, c2: Int)
        // Dimensional: these need `dimension`.
        case distance(p: Int, q: Int)
        case distanceX(p: Int, q: Int)
        case distanceY(p: Int, q: Int)
        case pointLineDistance(p: Int, line: Int)
        case offset(l1: Int, l2: Int)
        case angle(l1: Int, l2: Int)
        case radius(curve: Int)
        case diameter(curve: Int)

        public var isDimensional: Bool {
            switch self {
            case .distance, .distanceX, .distanceY, .pointLineDistance, .offset, .angle, .radius, .diameter: return true
            default: return false
            }
        }

        public var isAngular: Bool {
            if case .angle = self { return true }
            return false
        }

        public var displayName: String {
            switch self {
            case .coincident: return "Coincident"
            case .pointOnLine, .pointOnCurve: return "Point on curve"
            case .collinear: return "Collinear"
            case .concentric: return "Concentric"
            case .midpoint: return "Midpoint"
            case .fixed: return "Fix"
            case .parallel: return "Parallel"
            case .perpendicular: return "Perpendicular"
            case .horizontal, .horizontalPoints: return "Horizontal"
            case .vertical, .verticalPoints: return "Vertical"
            case .tangent, .tangentCurves: return "Tangent"
            case .curvature: return "Curvature (G2)"
            case .symmetric: return "Symmetric"
            case .equal: return "Equal"
            case .distance, .distanceX, .distanceY: return "Distance"
            case .pointLineDistance, .offset: return "Offset"
            case .angle: return "Angle"
            case .radius: return "Radius"
            case .diameter: return "Diameter"
            }
        }
    }

    public var id: Int
    public var kind: Kind
    public var dimension: SketchDimension?
}

/// The 2-D drawing inside a sketch feature: points, curves and the constraints between them.
/// Point 0 is the sketch origin and can never move, which is what lets a sketch become fully constrained.
public struct Sketch2D: Codable, Equatable, Sendable {
    public static let originID = 0

    public var points: [SketchPoint] = [SketchPoint(id: Sketch2D.originID, position: .zero)]
    public var curves: [SketchCurve] = []
    public var constraints: [SketchConstraint] = []
    public var nextID = 1

    public init() {}

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    // MARK: Lookups

    public func point(_ id: Int) -> SketchPoint? { points.first { $0.id == id } }
    public func position(_ id: Int) -> Vec2 { point(id)?.position ?? .zero }
    public func curve(_ id: Int) -> SketchCurve? { curves.first { $0.id == id } }

    public mutating func setPosition(_ id: Int, _ p: Vec2) {
        if let i = points.firstIndex(where: { $0.id == id }) { points[i].position = p }
    }

    /// Radius of a circle or arc (arcs measure from the centre to their start).
    public func radius(of curveID: Int) -> Double? {
        guard let c = curve(curveID) else { return nil }
        switch c.geometry {
        case .line: return nil
        case .circle(_, let r): return r
        case .arc(let center, let start, _): return simd_length(position(start) - position(center))
        }
    }

    public func center(of curveID: Int) -> Int? {
        guard let c = curve(curveID) else { return nil }
        switch c.geometry {
        case .line: return nil
        case .circle(let center, _): return center
        case .arc(let center, _, _): return center
        }
    }

    public func endpoints(of lineID: Int) -> (a: Int, b: Int)? {
        if case .line(let a, let b)? = curve(lineID)?.geometry { return (a, b) }
        return nil
    }

    // MARK: Building

    @discardableResult
    public mutating func addPoint(_ p: Vec2, construction: Bool = false) -> Int {
        let id = takeID()
        points.append(SketchPoint(id: id, position: p, isConstruction: construction))
        return id
    }

    @discardableResult
    public mutating func addLine(_ a: Vec2, _ b: Vec2, construction: Bool = false) -> Int {
        addLine(from: addPoint(a), to: addPoint(b), construction: construction)
    }

    @discardableResult
    public mutating func addLine(from a: Int, to b: Int, construction: Bool = false) -> Int {
        let id = takeID()
        curves.append(SketchCurve(id: id, geometry: .line(a: a, b: b), isConstruction: construction))
        return id
    }

    @discardableResult
    public mutating func addCircle(center: Vec2, radius: Double, construction: Bool = false) -> Int {
        addCircle(centerPoint: addPoint(center), radius: radius, construction: construction)
    }

    @discardableResult
    public mutating func addCircle(centerPoint: Int, radius: Double, construction: Bool = false) -> Int {
        let id = takeID()
        curves.append(SketchCurve(id: id, geometry: .circle(center: centerPoint, radius: radius), isConstruction: construction))
        return id
    }

    @discardableResult
    public mutating func addArc(center: Vec2, start: Vec2, end: Vec2, construction: Bool = false) -> Int {
        addArc(centerPoint: addPoint(center), startPoint: addPoint(start), endPoint: addPoint(end), construction: construction)
    }

    @discardableResult
    public mutating func addArc(centerPoint: Int, startPoint: Int, endPoint: Int, construction: Bool = false) -> Int {
        let id = takeID()
        curves.append(SketchCurve(id: id, geometry: .arc(center: centerPoint, start: startPoint, end: endPoint), isConstruction: construction))
        return id
    }

    /// Four lines joined at their corners, kept square by horizontal/vertical constraints.
    @discardableResult
    public mutating func addRectangle(_ p0: Vec2, _ p1: Vec2) -> [Int] {
        let lo = simd_min(p0, p1), hi = simd_max(p0, p1)
        let a = addPoint(lo), b = addPoint(Vec2(hi.x, lo.y)), c = addPoint(hi), d = addPoint(Vec2(lo.x, hi.y))
        let bottom = addLine(from: a, to: b), right = addLine(from: b, to: c)
        let top = addLine(from: c, to: d), left = addLine(from: d, to: a)
        addConstraint(.horizontal(line: bottom))
        addConstraint(.vertical(line: right))
        addConstraint(.horizontal(line: top))
        addConstraint(.vertical(line: left))
        return [bottom, right, top, left]
    }

    @discardableResult
    public mutating func addConstraint(_ kind: SketchConstraint.Kind, dimension: SketchDimension? = nil) -> Int {
        let id = takeID()
        constraints.append(SketchConstraint(id: id, kind: kind, dimension: dimension))
        return id
    }

    /// Adds a tangent constraint, working out which side of the line the curve already sits on.
    @discardableResult
    public mutating func addTangent(line: Int, curve: Int) -> Int? {
        guard let (a, b) = endpoints(of: line), let c = center(of: curve) else { return nil }
        let pa = position(a), d = position(b) - pa
        let side = d.cross(position(c) - pa) >= 0 ? 1.0 : -1.0
        return addConstraint(.tangent(line: line, curve: curve, side: side))
    }

    /// Tangent circles/arcs: internal when one sits inside the other.
    @discardableResult
    public mutating func addTangentCurves(_ c1: Int, _ c2: Int, curvature: Bool = false) -> Int? {
        guard let a = center(of: c1), let b = center(of: c2), let r1 = radius(of: c1), let r2 = radius(of: c2) else { return nil }
        let separation = simd_length(position(a) - position(b))
        let isInternal = separation < max(r1, r2)
        return addConstraint(curvature ? .curvature(c1: c1, c2: c2, isInternal: isInternal)
                                       : .tangentCurves(c1: c1, c2: c2, isInternal: isInternal))
    }

    // MARK: Removing

    public mutating func removeConstraint(_ id: Int) {
        constraints.removeAll { $0.id == id }
    }

    /// Removes a curve, the constraints that mention it and any points only it was using.
    public mutating func removeCurve(_ id: Int) {
        guard let c = curve(id) else { return }
        curves.removeAll { $0.id == id }
        constraints.removeAll { $0.kind.curveIDs.contains(id) }
        for p in c.pointIDs where p != Self.originID && !curves.contains(where: { $0.pointIDs.contains(p) }) {
            removePoint(p)
        }
    }

    public mutating func removePoint(_ id: Int) {
        guard id != Self.originID else { return }
        points.removeAll { $0.id == id }
        constraints.removeAll { $0.kind.pointIDs.contains(id) }
    }

    /// Names already used by dimensions in this sketch.
    public var dimensionNames: [String] { constraints.compactMap { $0.dimension?.name } }
}

extension SketchCurve {
    public var pointIDs: [Int] {
        switch geometry {
        case .line(let a, let b): return [a, b]
        case .circle(let c, _): return [c]
        case .arc(let c, let s, let e): return [c, s, e]
        }
    }

    public var isLine: Bool {
        if case .line = geometry { return true }
        return false
    }
}

extension SketchConstraint.Kind {
    public var pointIDs: [Int] {
        switch self {
        case .coincident(let p, let q), .horizontalPoints(let p, let q), .verticalPoints(let p, let q),
             .distance(let p, let q), .distanceX(let p, let q), .distanceY(let p, let q):
            return [p, q]
        case .pointOnLine(let p, _), .pointOnCurve(let p, _), .midpoint(let p, _), .fixed(let p, _), .pointLineDistance(let p, _):
            return [p]
        case .symmetric(let p, let q, _):
            return [p, q]
        default:
            return []
        }
    }

    public var curveIDs: [Int] {
        switch self {
        case .pointOnLine(_, let l), .pointOnCurve(_, let l), .midpoint(_, let l), .horizontal(let l), .vertical(let l),
             .pointLineDistance(_, let l), .radius(let l), .diameter(let l):
            return [l]
        case .collinear(let a, let b), .concentric(let a, let b), .parallel(let a, let b), .perpendicular(let a, let b),
             .equal(let a, let b), .offset(let a, let b), .angle(let a, let b):
            return [a, b]
        case .tangent(let a, let b, _), .tangentCurves(let a, let b, _), .curvature(let a, let b, _):
            return [a, b]
        case .symmetric(_, _, let axis):
            return [axis]
        default:
            return []
        }
    }
}
