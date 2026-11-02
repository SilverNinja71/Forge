import Foundation
import simd

public enum SketchTool: String, CaseIterable, Identifiable, Sendable {
    case select, line, rectangle, circle, arc, dimension

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .select: return "Select"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .circle: return "Circle"
        case .arc: return "Arc"
        case .dimension: return "Dimension"
        }
    }

    public var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arc: return "circle.lefthalf.filled"
        case .dimension: return "ruler"
        }
    }
}

/// The snapping grid: 0.1, 1 or 10 mm, or any custom size such as 1/16 inch.
public enum SketchGrid: Hashable, Sendable {
    case off
    case mm(Double)
    case inches(Double)

    public var spacing: Double? {
        switch self {
        case .off: return nil
        case .mm(let v): return v
        case .inches(let v): return v * 25.4
        }
    }

    public static let presets: [SketchGrid] = [.mm(0.1), .mm(1), .mm(10), .inches(0.125), .off]

    /// A custom size typed as a length: `0.5mm`, `1/16 in`, `2` (millimetres).
    public static func parse(_ text: String) -> SketchGrid? {
        // The unit applies to the whole fraction: "1/16 in" is a sixteenth of an inch, not one over sixteen inches.
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let isInches = trimmed.hasSuffix("in")
        let number = isInches || trimmed.hasSuffix("mm") ? String(trimmed.dropLast(2)) : trimmed
        guard let q = try? ExpressionEvaluator().evaluate(number), q.lengthPower == 0, q.value > 0 else { return nil }
        return isInches ? .inches(q.value) : .mm(q.value)
    }

    public var displayName: String {
        switch self {
        case .off: return "No grid"
        case .mm(let v): return "\(formatted(v)) mm"
        case .inches(let v): return "\(formatted(v)) in"
        }
    }

    private func formatted(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%g", v)
    }
}

/// A place the cursor has snapped to, and what a new point there should be tied to.
public struct SketchSnap: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case free, grid, existingPoint(Int), onCurve(Int), midpoint(Int)
    }

    public var position: Vec2
    public var kind: Kind
    /// Set when the cursor lines up with the start point: the "inference line" the user sees.
    public var inferred: SketchConstraint.Kind.Inference?
}

extension SketchConstraint.Kind {
    public enum Inference: Equatable, Sendable {
        case horizontal, vertical
    }
}

/// Selected things inside a sketch.
public struct SketchSelection: Equatable, Sendable {
    public var points: [Int] = []
    public var curves: [Int] = []
    public var constraint: Int?

    public var isEmpty: Bool { points.isEmpty && curves.isEmpty && constraint == nil }
    public init() {}
}

/// A constraint the current selection allows.
public struct ConstraintChoice: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var symbol: String
}

/// Everything about drawing in a sketch: tools, snapping, inference and constraint commands. It knows nothing
/// about the screen. Positions arrive in sketch millimetres, which also lets tests "draw" with it directly.
public struct SketchEditor: Sendable {
    public var sketch: Sketch2D
    public var tool: SketchTool = .select {
        didSet { if tool != oldValue { cancel() } }
    }
    public var grid: SketchGrid = .mm(1)
    public var selection = SketchSelection()
    /// Live state of a tool part-way through: the points clicked so far, and where the cursor is now.
    public private(set) var clicks: [ToolClick] = []
    public private(set) var cursor: SketchSnap?
    public private(set) var result: ConstraintSolver.Result
    /// The dimension waiting for the user to type its value.
    public var pendingDimension: PendingDimension?
    /// Name source, supplied by the document: dimension names are unique across the whole model.
    public var values: [String: Quantity]
    public var unitScale: Double

    private var draggingPoint: Int?
    private var draggingRadius: Int?

    public struct ToolClick: Equatable, Sendable {
        public var position: Vec2
        public var point: Int?
    }

    public struct PendingDimension: Equatable, Sendable {
        public var kind: SketchConstraint.Kind
        public var suggested: String
        public var at: Vec2
        public var isAngular: Bool { kind.isAngular }

        public init(kind: SketchConstraint.Kind, suggested: String, at: Vec2) {
            self.kind = kind
            self.suggested = suggested
            self.at = at
        }
    }

    public init(sketch: Sketch2D, values: [String: Quantity] = [:], unitScale: Double = 1) {
        self.sketch = sketch
        self.values = values
        self.unitScale = unitScale
        result = ConstraintSolver.analyse(sketch)
        solve()
    }

    public mutating func cancel() {
        clicks = []
        draggingPoint = nil
        draggingRadius = nil
        pendingDimension = nil
    }

    // MARK: Solving

    /// Refreshes dimension values from their formulas, then re-solves.
    public mutating func solve() {
        let dims = sketch.constraints.compactMap { c -> (name: String, expression: String)? in
            c.dimension.map { ($0.name, $0.expression) }
        }
        let (resolved, _) = ParameterSolver.evaluate(dims, known: values, defaultLength: unitScale)
        for i in sketch.constraints.indices {
            guard let dim = sketch.constraints[i].dimension, let q = resolved[dim.name] else { continue }
            let isAngle = sketch.constraints[i].kind.isAngular
            sketch.constraints[i].dimension?.value = isAngle ? q.value : (q.lengthPower == 1 ? q.value : q.value * unitScale)
        }
        result = ConstraintSolver.solve(&sketch)
    }

    // MARK: Snapping

    /// Works out what the cursor is snapping to. `tolerance` is in sketch mm (a few screen pixels' worth).
    public func snap(_ raw: Vec2, tolerance: Double, from anchor: Vec2? = nil, excluding: Set<Int> = []) -> SketchSnap {
        // Existing points win: drawing on them joins curves.
        var bestDistance = tolerance
        var result: SketchSnap?
        for p in sketch.points where !excluding.contains(p.id) {
            let d = simd_length(p.position - raw)
            if d < bestDistance {
                bestDistance = d
                result = SketchSnap(position: p.position, kind: .existingPoint(p.id))
            }
        }
        if let result { return result }
        for c in sketch.curves {
            if case .line(let a, let b) = c.geometry {
                let m = (sketch.position(a) + sketch.position(b)) / 2
                if simd_length(m - raw) < tolerance { return SketchSnap(position: m, kind: .midpoint(c.id)) }
            }
        }
        // Inference: lined up with where this line started.
        if let anchor {
            let d = raw - anchor
            if abs(d.y) < tolerance, abs(d.x) > tolerance {
                let x = gridded(raw).x
                return SketchSnap(position: Vec2(x, anchor.y), kind: .free, inferred: .horizontal)
            }
            if abs(d.x) < tolerance, abs(d.y) > tolerance {
                let y = gridded(raw).y
                return SketchSnap(position: Vec2(anchor.x, y), kind: .free, inferred: .vertical)
            }
        }
        // On a curve.
        for c in sketch.curves {
            if let projected = projected(raw, onto: c.id), simd_length(projected - raw) < tolerance * 0.6 {
                return SketchSnap(position: projected, kind: .onCurve(c.id))
            }
        }
        if grid.spacing != nil { return SketchSnap(position: gridded(raw), kind: .grid) }
        return SketchSnap(position: raw, kind: .free)
    }

    private func gridded(_ p: Vec2) -> Vec2 {
        guard let s = grid.spacing, s > 0 else { return p }
        return (p / s).rounded(.toNearestOrAwayFromZero) * s
    }

    private func projected(_ p: Vec2, onto id: Int) -> Vec2? {
        guard let c = sketch.curve(id) else { return nil }
        switch c.geometry {
        case .line(let a, let b):
            let pa = sketch.position(a), d = sketch.position(b) - pa
            let len2 = simd_length_squared(d)
            guard len2 > 0 else { return nil }
            let t = simd_dot(p - pa, d) / len2
            guard t >= 0, t <= 1 else { return nil }
            return pa + d * t
        case .circle(let center, let r):
            let cp = sketch.position(center)
            let d = p - cp
            guard simd_length(d) > 1e-9 else { return nil }
            return cp + simd_normalize(d) * r
        case .arc(let center, let s, let e):
            let cp = sketch.position(center)
            let d = p - cp
            guard simd_length(d) > 1e-9 else { return nil }
            let a0 = atan2(sketch.position(s).y - cp.y, sketch.position(s).x - cp.x)
            var sweep = atan2(sketch.position(e).y - cp.y, sketch.position(e).x - cp.x) - a0
            if sweep <= 0 { sweep += 2 * .pi }
            var a = atan2(d.y, d.x) - a0
            if a < 0 { a += 2 * .pi }
            guard a <= sweep else { return nil }
            return cp + simd_normalize(d) * simd_length(sketch.position(s) - cp)
        }
    }

    /// The nearest curve within `tolerance`.
    public func hitCurve(_ p: Vec2, tolerance: Double) -> Int? {
        var best: Int?
        var bestD = tolerance
        for c in sketch.curves {
            if let q = projected(p, onto: c.id) {
                let d = simd_length(q - p)
                if d < bestD {
                    bestD = d
                    best = c.id
                }
            }
        }
        return best
    }

    public func hitPoint(_ p: Vec2, tolerance: Double) -> Int? {
        var best: Int?
        var bestD = tolerance
        for q in sketch.points {
            let d = simd_length(q.position - p)
            if d < bestD {
                bestD = d
                best = q.id
            }
        }
        return best
    }

    // MARK: Pointer

    public mutating func pointerMoved(to raw: Vec2, tolerance: Double) {
        let anchor = (tool == .line || tool == .rectangle) ? clicks.last?.position : nil
        cursor = snap(raw, tolerance: tolerance, from: tool == .line ? anchor : nil)
    }

    public mutating func pointerDown(at raw: Vec2, tolerance: Double, extendSelection: Bool = false) {
        pointerMoved(to: raw, tolerance: tolerance)
        guard let snap = cursor else { return }
        switch tool {
        case .select:
            if let p = hitPoint(raw, tolerance: tolerance) {
                if !extendSelection { selection = SketchSelection() }
                toggle(&selection.points, p)
                if p != Sketch2D.originID { draggingPoint = p }
            } else if let c = hitCurve(raw, tolerance: tolerance) {
                if !extendSelection { selection = SketchSelection() }
                toggle(&selection.curves, c)
                if case .circle? = sketch.curve(c)?.geometry { draggingRadius = c }
            } else if !extendSelection {
                selection = SketchSelection()
            }
        case .line:
            placeLinePoint(snap)
        case .rectangle:
            if let first = clicks.first {
                guard simd_length(first.position - snap.position) > 1e-6 else { return }
                let lines = sketch.addRectangle(first.position, snap.position)
                tieCorner(first, near: lines)
                tieCorner(ToolClick(position: snap.position, point: pointID(in: snap)), near: lines)
                clicks = []
                solve()
            } else {
                clicks = [ToolClick(position: snap.position, point: pointID(in: snap))]
            }
        case .circle:
            if let center = clicks.first {
                let r = simd_length(snap.position - center.position)
                guard r > 1e-6 else { return }
                let cp = center.point ?? sketch.addPoint(center.position)
                sketch.addCircle(centerPoint: cp, radius: r)
                clicks = []
                solve()
            } else {
                clicks = [ToolClick(position: snap.position, point: pointID(in: snap))]
            }
        case .arc:
            clicks.append(ToolClick(position: snap.position, point: pointID(in: snap)))
            if clicks.count == 3 {
                let c = clicks[0].point ?? sketch.addPoint(clicks[0].position)
                let s = clicks[1].point ?? sketch.addPoint(clicks[1].position)
                let r = simd_length(clicks[1].position - clicks[0].position)
                let dirE = clicks[2].position - clicks[0].position
                let endPos = clicks[0].position + (simd_length(dirE) > 1e-9 ? simd_normalize(dirE) : Vec2(1, 0)) * r
                let e = clicks[2].point ?? sketch.addPoint(endPos)
                sketch.addArc(centerPoint: c, startPoint: s, endPoint: e)
                clicks = []
                solve()
            }
        case .dimension:
            dimensionClick(raw, tolerance: tolerance)
        }
    }

    public mutating func pointerDragged(to raw: Vec2, tolerance: Double) {
        if let p = draggingPoint {
            let target = snap(raw, tolerance: tolerance, excluding: [p]).position
            if ConstraintSolver.drag(&sketch, point: p, to: target) {
                result = ConstraintSolver.analyse(sketch)
            }
        } else if let c = draggingRadius, let center = sketch.center(of: c) {
            let r = simd_length(gridded(raw) - sketch.position(center))
            if r > 1e-6, ConstraintSolver.drag(&sketch, radiusOf: c, to: r) {
                result = ConstraintSolver.analyse(sketch)
            }
        }
    }

    public mutating func pointerUp() {
        draggingPoint = nil
        draggingRadius = nil
    }

    private func toggle(_ list: inout [Int], _ id: Int) {
        if let i = list.firstIndex(of: id) { list.remove(at: i) } else { list.append(id) }
    }

    private func pointID(in snap: SketchSnap) -> Int? {
        if case .existingPoint(let id) = snap.kind { return id }
        return nil
    }

    private mutating func placeLinePoint(_ snap: SketchSnap) {
        guard let last = clicks.last else {
            clicks = [ToolClick(position: snap.position, point: pointID(in: snap))]
            return
        }
        guard simd_length(last.position - snap.position) > 1e-6 else { return }
        let from = last.point ?? sketch.addPoint(last.position)
        let to = pointID(in: snap) ?? sketch.addPoint(snap.position)
        let line = sketch.addLine(from: from, to: to)
        switch snap.inferred {
        case .horizontal?: sketch.addConstraint(.horizontal(line: line))
        case .vertical?: sketch.addConstraint(.vertical(line: line))
        case nil: break
        }
        attach(pointAt: to, snap: snap, drawnLine: line)
        // Arriving on an existing point closes the chain; otherwise keep going from here.
        if pointID(in: snap) != nil {
            clicks = []
        } else {
            clicks.append(ToolClick(position: snap.position, point: to))
        }
        solve()
    }

    private mutating func attach(pointAt id: Int, snap: SketchSnap, drawnLine: Int) {
        switch snap.kind {
        case .midpoint(let line) where line != drawnLine:
            sketch.addConstraint(.midpoint(p: id, line: line))
        case .onCurve(let c) where c != drawnLine:
            if sketch.curve(c)?.isLine == true {
                sketch.addConstraint(.pointOnLine(p: id, line: c))
            } else {
                sketch.addConstraint(.pointOnCurve(p: id, curve: c))
            }
        default:
            break
        }
    }

    /// A rectangle drawn from an existing point starts joined to it.
    private mutating func tieCorner(_ click: ToolClick, near lines: [Int]) {
        guard let existing = click.point else { return }
        for line in lines {
            guard let (a, b) = sketch.endpoints(of: line) else { continue }
            for p in [a, b] where simd_length(sketch.position(p) - click.position) < 1e-9 && p != existing {
                if !sketch.constraints.contains(where: { $0.kind == .coincident(p: p, q: existing) }) {
                    sketch.addConstraint(.coincident(p: p, q: existing))
                }
                return
            }
        }
    }

    // MARK: Dimensions

    private mutating func dimensionClick(_ raw: Vec2, tolerance: Double) {
        if let p = hitPoint(raw, tolerance: tolerance) {
            selection.points.append(p)
            if selection.points.count == 2 {
                let a = selection.points[0], b = selection.points[1]
                selection = SketchSelection()
                let d = simd_length(sketch.position(a) - sketch.position(b))
                pendingDimension = PendingDimension(kind: .distance(p: a, q: b), suggested: format(d), at: raw)
            }
            return
        }
        guard let c = hitCurve(raw, tolerance: tolerance), let curve = sketch.curve(c) else { return }
        if let first = selection.curves.first, first != c, let l0 = sketch.endpoints(of: first), let l1 = sketch.endpoints(of: c) {
            // Two lines: an angle if they aren't parallel, otherwise the gap between them.
            let u = sketch.position(l0.b) - sketch.position(l0.a), v = sketch.position(l1.b) - sketch.position(l1.a)
            let theta = atan2(u.cross(v), u.dot(v))
            selection = SketchSelection()
            if abs(sin(theta)) < 1e-6 {
                let d = abs(u.cross(sketch.position(l1.a) - sketch.position(l0.a))) / simd_length(u)
                pendingDimension = PendingDimension(kind: .offset(l1: first, l2: c), suggested: format(d), at: raw)
            } else {
                pendingDimension = PendingDimension(kind: .angle(l1: first, l2: c), suggested: String(format: "%.4gdeg", theta * 180 / .pi), at: raw)
            }
            return
        }
        switch curve.geometry {
        case .line(let a, let b):
            if selection.curves.isEmpty {
                // Offer the line's length straight away; clicking a second line instead turns this into an angle.
                selection.curves = [c]
                let d = simd_length(sketch.position(a) - sketch.position(b))
                pendingDimension = PendingDimension(kind: .distance(p: a, q: b), suggested: format(d), at: raw)
            }
        case .circle(_, let r):
            selection = SketchSelection()
            pendingDimension = PendingDimension(kind: .diameter(curve: c), suggested: format(r * 2), at: raw)
        case .arc:
            selection = SketchSelection()
            pendingDimension = PendingDimension(kind: .radius(curve: c), suggested: format(sketch.radius(of: c) ?? 0), at: raw)
        }
    }

    private func format(_ mm: Double) -> String {
        let value = mm / unitScale
        let text = String(format: "%.4f", value).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        return text + (unitScale == 25.4 ? "in" : "mm")
    }

    /// Adds the dimension the user just typed. Returns false (and adds nothing) when the formula doesn't evaluate.
    @discardableResult
    public mutating func commitDimension(expression: String, name: String) -> Bool {
        guard let pending = pendingDimension else { return false }
        let known = values.merging(currentDimensionValues()) { a, _ in a }
        let ev = ExpressionEvaluator(defaultLength: unitScale) { known[$0] }
        let value: Double
        do {
            value = pending.kind.isAngular ? try ev.angle(expression) : try ev.length(expression)
        } catch {
            return false
        }
        // An angle typed as a bare number means degrees: store it explicitly so later reads agree.
        let isBareAngle = pending.kind.isAngular && !expression.contains("deg") && !expression.contains("rad")
            && ExpressionEvaluator.references(expression).isEmpty
        sketch.addConstraint(pending.kind, dimension: SketchDimension(name: name, expression: isBareAngle ? "\(expression)deg" : expression, value: value))
        pendingDimension = nil
        selection = SketchSelection()
        solve()
        return true
    }

    private func currentDimensionValues() -> [String: Quantity] {
        var out: [String: Quantity] = [:]
        for c in sketch.constraints {
            guard let d = c.dimension else { continue }
            out[d.name] = c.kind.isAngular ? Quantity(d.value) : .length(d.value)
        }
        return out
    }

    /// Changes an existing dimension's formula.
    @discardableResult
    public mutating func editDimension(_ constraintID: Int, expression: String) -> Bool {
        guard let i = sketch.constraints.firstIndex(where: { $0.id == constraintID }), sketch.constraints[i].dimension != nil else { return false }
        var known = values
        for c in sketch.constraints where c.id != constraintID {
            if let d = c.dimension { known[d.name] = c.kind.isAngular ? Quantity(d.value) : .length(d.value) }
        }
        let ev = ExpressionEvaluator(defaultLength: unitScale) { known[$0] }
        let isAngle = sketch.constraints[i].kind.isAngular
        guard (try? (isAngle ? ev.angle(expression) : ev.length(expression))) != nil else { return false }
        let bare = isAngle && !expression.contains("deg") && !expression.contains("rad") && ExpressionEvaluator.references(expression).isEmpty
        sketch.constraints[i].dimension?.expression = bare ? "\(expression)deg" : expression
        solve()
        return true
    }

    // MARK: Editing

    public mutating func deleteSelection() {
        if let c = selection.constraint { sketch.removeConstraint(c) }
        for c in selection.curves { sketch.removeCurve(c) }
        for p in selection.points { sketch.removePoint(p) }
        selection = SketchSelection()
        solve()
    }

    public mutating func toggleConstruction() {
        for id in selection.curves {
            if let i = sketch.curves.firstIndex(where: { $0.id == id }) { sketch.curves[i].isConstruction.toggle() }
        }
        solve()
    }

    public mutating func removeConstraint(_ id: Int) {
        sketch.removeConstraint(id)
        solve()
    }

    // MARK: Constraint commands

    /// Which constraints make sense for what's selected.
    public var availableConstraints: [ConstraintChoice] {
        let lines = selection.curves.filter { sketch.curve($0)?.isLine == true }
        let rounds = selection.curves.filter { sketch.curve($0)?.isLine == false }
        let pts = selection.points
        var out: [ConstraintChoice] = []
        func add(_ name: String, _ symbol: String) { out.append(ConstraintChoice(name: name, symbol: symbol)) }
        if pts.count == 2, selection.curves.isEmpty {
            add("Coincident", "smallcircle.filled.circle")
            add("Horizontal", "arrow.left.and.right")
            add("Vertical", "arrow.up.and.down")
        }
        if pts.count == 1, selection.curves.isEmpty { add(isFixed(pts[0]) ? "Unfix" : "Fix", "lock") }
        if lines.count >= 1, rounds.isEmpty, pts.isEmpty {
            add("Horizontal", "arrow.left.and.right")
            add("Vertical", "arrow.up.and.down")
        }
        if lines.count == 2, rounds.isEmpty, pts.isEmpty {
            add("Parallel", "equal")
            add("Perpendicular", "angle")
            add("Collinear", "line.diagonal")
            add("Equal", "equal.circle")
        }
        if lines.count == 1, rounds.count == 1, pts.isEmpty { add("Tangent", "circle.and.line.horizontal") }
        if rounds.count == 2, lines.isEmpty, pts.isEmpty {
            add("Tangent", "circle.and.line.horizontal")
            add("Curvature (G2)", "point.topleft.down.to.point.bottomright.curvepath")
            add("Concentric", "circle.circle")
            add("Equal", "equal.circle")
        }
        if pts.count == 1, lines.count == 1, rounds.isEmpty {
            add("Point on Line", "point.bottomleft.forward.to.point.topright.scurvepath")
            add("Midpoint", "circle.and.line.horizontal")
        }
        if pts.count == 1, rounds.count == 1, lines.isEmpty { add("Point on Curve", "point.bottomleft.forward.to.point.topright.scurvepath") }
        if pts.count == 2, lines.count == 1, rounds.isEmpty { add("Symmetric", "arrow.left.and.right.righttriangle.left.righttriangle.right") }
        return out
    }

    private func isFixed(_ p: Int) -> Bool {
        sketch.constraints.contains {
            if case .fixed(let q, _) = $0.kind { return p == q }
            return false
        }
    }

    /// Applies the constraint named in `availableConstraints` to the current selection.
    public mutating func applyConstraint(named name: String) {
        let lines = selection.curves.filter { sketch.curve($0)?.isLine == true }
        let rounds = selection.curves.filter { sketch.curve($0)?.isLine == false }
        let pts = selection.points
        switch name {
        case "Coincident" where pts.count == 2:
            sketch.addConstraint(.coincident(p: pts[0], q: pts[1]))
        case "Fix" where pts.count == 1:
            sketch.addConstraint(.fixed(p: pts[0], at: sketch.position(pts[0])))
        case "Unfix" where pts.count == 1:
            sketch.constraints.removeAll {
                if case .fixed(let q, _) = $0.kind { return q == pts[0] }
                return false
            }
        case "Horizontal":
            if pts.count == 2 { sketch.addConstraint(.horizontalPoints(p: pts[0], q: pts[1])) }
            for l in lines { sketch.addConstraint(.horizontal(line: l)) }
        case "Vertical":
            if pts.count == 2 { sketch.addConstraint(.verticalPoints(p: pts[0], q: pts[1])) }
            for l in lines { sketch.addConstraint(.vertical(line: l)) }
        case "Parallel" where lines.count == 2:
            sketch.addConstraint(.parallel(l1: lines[0], l2: lines[1]))
        case "Perpendicular" where lines.count == 2:
            sketch.addConstraint(.perpendicular(l1: lines[0], l2: lines[1]))
        case "Collinear" where lines.count == 2:
            sketch.addConstraint(.collinear(l1: lines[0], l2: lines[1]))
        case "Equal":
            let pair = lines.count == 2 ? lines : rounds
            if pair.count == 2 { sketch.addConstraint(.equal(c1: pair[0], c2: pair[1])) }
        case "Tangent":
            if lines.count == 1, rounds.count == 1 {
                sketch.addTangent(line: lines[0], curve: rounds[0])
            } else if rounds.count == 2 {
                sketch.addTangentCurves(rounds[0], rounds[1])
            }
        case "Curvature (G2)" where rounds.count == 2:
            sketch.addTangentCurves(rounds[0], rounds[1], curvature: true)
        case "Concentric" where rounds.count == 2:
            sketch.addConstraint(.concentric(c1: rounds[0], c2: rounds[1]))
        case "Point on Line" where pts.count == 1 && lines.count == 1:
            sketch.addConstraint(.pointOnLine(p: pts[0], line: lines[0]))
        case "Midpoint" where pts.count == 1 && lines.count == 1:
            sketch.addConstraint(.midpoint(p: pts[0], line: lines[0]))
        case "Point on Curve" where pts.count == 1 && rounds.count == 1:
            sketch.addConstraint(.pointOnCurve(p: pts[0], curve: rounds[0]))
        case "Symmetric" where pts.count == 2 && lines.count == 1:
            sketch.addConstraint(.symmetric(p: pts[0], q: pts[1], axis: lines[0]))
        default:
            return
        }
        selection = SketchSelection()
        solve()
    }
}
