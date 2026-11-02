import Foundation
import simd

/// A value plus its exact derivative with respect to each sketch unknown ("automatic differentiation").
/// Writing residuals with this type means the solver's Jacobian is exact, not a finite-difference estimate.
struct Dual {
    var v: Double
    /// Sorted (unknown index, derivative) pairs. Most residuals touch only a handful of unknowns.
    var g: [(Int32, Double)]

    init(_ v: Double) {
        self.v = v
        g = []
    }

    init(_ v: Double, variable: Int) {
        self.v = v
        g = [(Int32(variable), 1)]
    }

    init(v: Double, g: [(Int32, Double)]) {
        self.v = v
        self.g = g
    }

    private static func combine(_ a: [(Int32, Double)], _ ka: Double, _ b: [(Int32, Double)], _ kb: Double) -> [(Int32, Double)] {
        var out: [(Int32, Double)] = []
        out.reserveCapacity(a.count + b.count)
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if j >= b.count || (i < a.count && a[i].0 < b[j].0) {
                out.append((a[i].0, a[i].1 * ka))
                i += 1
            } else if i >= a.count || b[j].0 < a[i].0 {
                out.append((b[j].0, b[j].1 * kb))
                j += 1
            } else {
                out.append((a[i].0, a[i].1 * ka + b[j].1 * kb))
                i += 1
                j += 1
            }
        }
        return out
    }

    static func + (a: Dual, b: Dual) -> Dual { Dual(v: a.v + b.v, g: combine(a.g, 1, b.g, 1)) }
    static func - (a: Dual, b: Dual) -> Dual { Dual(v: a.v - b.v, g: combine(a.g, 1, b.g, -1)) }
    static func * (a: Dual, b: Dual) -> Dual { Dual(v: a.v * b.v, g: combine(a.g, b.v, b.g, a.v)) }
    static func / (a: Dual, b: Dual) -> Dual {
        Dual(v: a.v / b.v, g: combine(a.g, 1 / b.v, b.g, -a.v / (b.v * b.v)))
    }
    static func * (a: Dual, k: Double) -> Dual { Dual(v: a.v * k, g: a.g.map { ($0.0, $0.1 * k) }) }
    static func - (a: Dual, k: Double) -> Dual { Dual(v: a.v - k, g: a.g) }
    static prefix func - (a: Dual) -> Dual { a * -1 }

    func squareRoot() -> Dual {
        let root = Foundation.sqrt(max(v, 0))
        let k = root > 1e-150 ? 0.5 / root : 0
        return Dual(v: root, g: g.map { ($0.0, $0.1 * k) })
    }

    static func atan2(_ y: Dual, _ x: Dual) -> Dual {
        let d = max(x.v * x.v + y.v * y.v, 1e-300)
        return Dual(v: Foundation.atan2(y.v, x.v), g: combine(y.g, x.v / d, x.g, -y.v / d))
    }
}

/// Newton-Raphson solver for sketch constraints, with the bookkeeping that drives Forge's colours.
///
/// Every constraint becomes one or two equations ("residuals") that are zero when it's satisfied. Each
/// iteration linearises them (the Jacobian J) and moves the unknowns x by the smallest step solving
/// `J·dx = -r`, so geometry moves as little as possible. A rank-revealing QR factorisation of Jᵀ gives that
/// step *and* the analysis: rank < rows means redundant or conflicting constraints; unknowns − rank is the
/// number of degrees of freedom left.
public enum ConstraintSolver {
    public enum Status: String, Codable, Sendable {
        /// Blue: some geometry can still move.
        case underConstrained
        /// Black: nothing can move, nothing contradicts.
        case fullyConstrained
        /// Red: at least one constraint is redundant or impossible.
        case overConstrained
    }

    public struct Result: Equatable, Sendable {
        public var status: Status
        /// Degrees of freedom left (how many independent ways the sketch can still move).
        public var degreesOfFreedom: Int
        public var converged: Bool
        /// Largest constraint error left, in mm (or radians for angles).
        public var residual: Double
        public var iterations: Int
        /// Constraints that can't be satisfied, or that add nothing because others already imply them.
        public var conflicting: Set<Int>
        /// Points and curves that can still move. Used for per-entity blue/black colouring.
        public var freePoints: Set<Int>
        public var freeRadii: Set<Int>
    }

    /// Target accuracy, far below the sub-micron (0.001 mm) the brief asks for.
    public static let tolerance = 1e-9

    // MARK: Residuals

    private struct System {
        let sketch: Sketch2D
        var pointVars: [Int: Int] = [:]   // point id → index of x (y is index + 1)
        var radiusVars: [Int: Int] = [:]  // circle curve id → index
        var x: [Double] = []
        var pointIndex: [Int: Int] = [:]
        var curveIndex: [Int: Int] = [:]
        var positions: [Int: Vec2] = [:]

        init(sketch: Sketch2D, pinned: Set<Int>, pinnedRadii: Set<Int>) {
            self.sketch = sketch
            for p in sketch.points {
                positions[p.id] = p.position
                guard p.id != Sketch2D.originID, !pinned.contains(p.id) else { continue }
                pointVars[p.id] = x.count
                x += [p.position.x, p.position.y]
            }
            for c in sketch.curves {
                if case .circle(_, let r) = c.geometry, !pinnedRadii.contains(c.id) {
                    radiusVars[c.id] = x.count
                    x.append(r)
                }
            }
            for (i, c) in sketch.curves.enumerated() { curveIndex[c.id] = i }
        }

        func px(_ id: Int) -> (x: Dual, y: Dual) {
            if let i = pointVars[id] { return (Dual(x[i], variable: i), Dual(x[i + 1], variable: i + 1)) }
            let p = positions[id] ?? .zero
            return (Dual(p.x), Dual(p.y))
        }

        func line(_ id: Int) -> (ax: Dual, ay: Dual, dx: Dual, dy: Dual, len: Dual)? {
            guard let i = curveIndex[id], case .line(let a, let b) = sketch.curves[i].geometry else { return nil }
            let pa = px(a), pb = px(b)
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            return (pa.x, pa.y, dx, dy, length(dx, dy))
        }

        func length(_ dx: Dual, _ dy: Dual) -> Dual {
            (dx * dx + dy * dy).squareRoot()
        }

        /// Centre and radius of a circle or arc.
        func round(_ id: Int) -> (cx: Dual, cy: Dual, r: Dual)? {
            guard let i = curveIndex[id] else { return nil }
            switch sketch.curves[i].geometry {
            case .line:
                return nil
            case .circle(let center, let radius):
                let c = px(center)
                if let v = radiusVars[id] { return (c.x, c.y, Dual(x[v], variable: v)) }
                return (c.x, c.y, Dual(radius))
            case .arc(let center, let start, _):
                let c = px(center), s = px(start)
                return (c.x, c.y, length(s.x - c.x, s.y - c.y))
            }
        }

        /// Signed distance from a point to a line (positive on its left).
        func signedDistance(_ p: (x: Dual, y: Dual), line l: (ax: Dual, ay: Dual, dx: Dual, dy: Dual, len: Dual)) -> Dual {
            (l.dx * (p.y - l.ay) - l.dy * (p.x - l.ax)) / l.len
        }

        /// Appends the residuals of one constraint. Each has units of mm or radians.
        func residuals(of c: SketchConstraint) -> [Dual] {
            let value = c.dimension?.value ?? 0
            switch c.kind {
            case .coincident(let p, let q):
                let a = px(p), b = px(q)
                return [a.x - b.x, a.y - b.y]
            case .pointOnLine(let p, let line):
                guard let l = self.line(line) else { return [] }
                return [signedDistance(px(p), line: l)]
            case .pointOnCurve(let p, let curve):
                guard let r = round(curve) else { return [] }
                let a = px(p)
                return [length(a.x - r.cx, a.y - r.cy) - r.r]
            case .collinear(let l1, let l2):
                guard let a = line(l1), let (p, q) = sketch.endpoints(of: l2) else { return [] }
                return [signedDistance(px(p), line: a), signedDistance(px(q), line: a)]
            case .concentric(let c1, let c2):
                guard let a = round(c1), let b = round(c2) else { return [] }
                return [a.cx - b.cx, a.cy - b.cy]
            case .midpoint(let p, let line):
                guard let (a, b) = sketch.endpoints(of: line) else { return [] }
                let m = px(p), pa = px(a), pb = px(b)
                return [m.x * 2 - pa.x - pb.x, m.y * 2 - pa.y - pb.y]
            case .fixed(let p, let at):
                let a = px(p)
                return [a.x - at.x, a.y - at.y]
            case .parallel(let l1, let l2):
                guard let a = line(l1), let b = line(l2) else { return [] }
                return [wrapped(angleBetween(a, b), period: .pi)]
            case .perpendicular(let l1, let l2):
                guard let a = line(l1), let b = line(l2) else { return [] }
                return [wrapped(angleBetween(a, b) - .pi / 2, period: .pi)]
            case .horizontal(let id):
                guard let (a, b) = sketch.endpoints(of: id) else { return [] }
                return [px(a).y - px(b).y]
            case .vertical(let id):
                guard let (a, b) = sketch.endpoints(of: id) else { return [] }
                return [px(a).x - px(b).x]
            case .horizontalPoints(let p, let q):
                return [px(p).y - px(q).y]
            case .verticalPoints(let p, let q):
                return [px(p).x - px(q).x]
            case .tangent(let lineID, let curve, let side):
                guard let l = line(lineID), let r = round(curve) else { return [] }
                return [signedDistance((r.cx, r.cy), line: l) * side - r.r]
            case .tangentCurves(let c1, let c2, let isInternal):
                return curveTangent(c1, c2, isInternal)
            case .curvature(let c1, let c2, let isInternal):
                guard let a = round(c1), let b = round(c2) else { return [] }
                return curveTangent(c1, c2, isInternal) + [a.r - b.r]
            case .symmetric(let p, let q, let axis):
                guard let l = line(axis) else { return [] }
                let a = px(p), b = px(q)
                let mid = (x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
                return [signedDistance(mid, line: l), ((a.x - b.x) * l.dx + (a.y - b.y) * l.dy) / l.len]
            case .equal(let c1, let c2):
                if let a = line(c1), let b = line(c2) { return [a.len - b.len] }
                if let a = round(c1), let b = round(c2) { return [a.r - b.r] }
                return []
            case .distance(let p, let q):
                let a = px(p), b = px(q)
                return [length(b.x - a.x, b.y - a.y) - value]
            case .distanceX(let p, let q):
                return [px(q).x - px(p).x - value]
            case .distanceY(let p, let q):
                return [px(q).y - px(p).y - value]
            case .pointLineDistance(let p, let id):
                guard let l = line(id) else { return [] }
                let d = signedDistance(px(p), line: l)
                return [d - (d.v >= 0 ? value : -value)]
            case .offset(let l1, let l2):
                guard let a = line(l1), let (p, q) = sketch.endpoints(of: l2) else { return [] }
                let d1 = signedDistance(px(p), line: a), d2 = signedDistance(px(q), line: a)
                let target = d1.v + d2.v >= 0 ? value : -value
                return [d1 - target, d2 - target]
            case .angle(let l1, let l2):
                guard let a = line(l1), let b = line(l2) else { return [] }
                return [wrapped(angleBetween(a, b) - value, period: 2 * .pi)]
            case .radius(let curve):
                guard let r = round(curve) else { return [] }
                return [r.r - value]
            case .diameter(let curve):
                guard let r = round(curve) else { return [] }
                return [r.r * 2 - value]
            }
        }

        /// The angle itself, not its sine or cosine, whose slope vanishes at 0° and 90°: lines that start exactly
        /// parallel can still be pulled perpendicular.
        private func angleBetween(_ a: (ax: Dual, ay: Dual, dx: Dual, dy: Dual, len: Dual),
                                  _ b: (ax: Dual, ay: Dual, dx: Dual, dy: Dual, len: Dual)) -> Dual {
            Dual.atan2(a.dx * b.dy - a.dy * b.dx, a.dx * b.dx + a.dy * b.dy)
        }

        /// Keeps an angular error in the half-period around zero, so the smaller rotation is always chosen.
        private func wrapped(_ angle: Dual, period: Double) -> Dual {
            Dual(v: remainder(angle.v, period), g: angle.g)
        }

        private func curveTangent(_ c1: Int, _ c2: Int, _ isInternal: Bool) -> [Dual] {
            guard let a = round(c1), let b = round(c2) else { return [] }
            let separation = length(a.cx - b.cx, a.cy - b.cy)
            if !isInternal { return [separation - a.r - b.r] }
            // For internal tangency the larger circle's radius comes first; its sign is decided by the current sizes.
            return [a.r.v >= b.r.v ? separation - (a.r - b.r) : separation - (b.r - a.r)]
        }

        /// All residuals, with the constraint id each row came from (-1 for built-in arc equations).
        func evaluate() -> (rows: [Dual], owners: [Int]) {
            var rows: [Dual] = []
            var owners: [Int] = []
            for curve in sketch.curves {
                if case .arc(let center, let start, let end) = curve.geometry {
                    let c = px(center), s = px(start), e = px(end)
                    rows.append(length(s.x - c.x, s.y - c.y) - length(e.x - c.x, e.y - c.y))
                    owners.append(-1)
                }
            }
            for c in sketch.constraints {
                for r in residuals(of: c) {
                    rows.append(r)
                    owners.append(c.id)
                }
            }
            return (rows, owners)
        }
    }

    // MARK: Solving

    /// Moves geometry to satisfy every constraint and reports the sketch's status. `pinned` points and
    /// `pinnedRadii` circles stay exactly where they are, which is how dragging works.
    @discardableResult
    public static func solve(_ sketch: inout Sketch2D, pinned: Set<Int> = [], pinnedRadii: Set<Int> = [],
                             maxIterations: Int = 60) -> Result {
        var system = System(sketch: sketch, pinned: pinned, pinnedRadii: pinnedRadii)
        var iterations = 0
        var (rows, owners) = system.evaluate()
        var norm = rows.reduce(0) { max($0, abs($1.v)) }
        let scale = max(1, sketch.points.reduce(1.0) { max($0, abs($1.position.x), abs($1.position.y)) })
        var stalled = false

        while norm > tolerance, iterations < maxIterations, !rows.isEmpty, !system.x.isEmpty {
            iterations += 1
            let step = minimumNormStep(rows: rows, unknowns: system.x.count).step
            // Limit the step so a far-off guess can't fling geometry away, then back off until the error shrinks.
            let biggest = step.reduce(0) { max($0, abs($1)) }
            var alpha = biggest > scale ? scale / biggest : 1
            let start = system.x
            var improved = false
            for _ in 0..<12 {
                system.x = zip(start, step).map { $0 + $1 * alpha }
                let trial = system.evaluate().rows
                let n = trial.reduce(0) { max($0, abs($1.v)) }
                if n < norm || n <= tolerance {
                    rows = trial
                    norm = n
                    improved = true
                    break
                }
                alpha *= 0.5
            }
            if !improved {
                system.x = start
                stalled = true
                break
            }
        }

        write(system, into: &sketch)
        (rows, owners) = system.evaluate()
        norm = rows.reduce(0) { max($0, abs($1.v)) }
        let converged = norm <= max(tolerance, 1e-8) && !(stalled && norm > 1e-8)
        return analyse(system: system, rows: rows, owners: owners, residual: norm, converged: converged, iterations: iterations)
    }

    private static func write(_ system: System, into sketch: inout Sketch2D) {
        for i in sketch.points.indices {
            if let v = system.pointVars[sketch.points[i].id] {
                sketch.points[i].position = Vec2(system.x[v], system.x[v + 1])
            }
        }
        for i in sketch.curves.indices {
            if let v = system.radiusVars[sketch.curves[i].id], case .circle(let center, _) = sketch.curves[i].geometry {
                sketch.curves[i].geometry = .circle(center: center, radius: system.x[v])
            }
        }
    }

    /// Reports the current state of a sketch without moving anything.
    public static func analyse(_ sketch: Sketch2D) -> Result {
        let system = System(sketch: sketch, pinned: [], pinnedRadii: [])
        let (rows, owners) = system.evaluate()
        let norm = rows.reduce(0) { max($0, abs($1.v)) }
        return analyse(system: system, rows: rows, owners: owners, residual: norm, converged: norm <= 1e-8, iterations: 0)
    }

    private static func analyse(system: System, rows: [Dual], owners: [Int], residual: Double, converged: Bool, iterations: Int) -> Result {
        let n = system.x.count
        let factored = minimumNormStep(rows: rows, unknowns: n, wantNullSpace: true)
        var conflicting = Set<Int>()
        for row in factored.dependentRows where owners[row] >= 0 { conflicting.insert(owners[row]) }
        // A constraint whose own equation is still wrong after solving is conflicting too.
        if !converged {
            for (row, value) in rows.enumerated() where abs(value.v) > 1e-8 && owners[row] >= 0 { conflicting.insert(owners[row]) }
        }
        let dof = n - factored.rank
        // A variable moves if any direction in the null space of J changes it.
        var freePoints = Set<Int>(), freeRadii = Set<Int>()
        let moving = factored.freeVariables
        for (id, i) in system.pointVars where moving[i] || moving[i + 1] { freePoints.insert(id) }
        for (id, i) in system.radiusVars where moving[i] { freeRadii.insert(id) }
        let status: Status = !conflicting.isEmpty || !converged ? .overConstrained : (dof == 0 ? .fullyConstrained : .underConstrained)
        return Result(status: status, degreesOfFreedom: dof, converged: converged, residual: residual, iterations: iterations,
                      conflicting: conflicting, freePoints: freePoints, freeRadii: freeRadii)
    }

    // MARK: Linear algebra

    private struct Factored {
        var step: [Double]
        var rank: Int
        var dependentRows: [Int]
        var freeVariables: [Bool]
    }

    /// Householder QR with column pivoting of Jᵀ (one column per equation). Rows are normalised first, so a
    /// long line's weak angle equation isn't mistaken for a dependent one. Columns the pivoting never needed
    /// are the dependent equations. Returns the minimum-norm solution of J·dx = -r.
    private static func minimumNormStep(rows: [Dual], unknowns n: Int, wantNullSpace: Bool = false) -> Factored {
        let m = rows.count
        var a = [Double](repeating: 0, count: n * m)  // column-major n×m, a[i + j*n]
        var rhs = [Double](repeating: 0, count: m)
        for (j, row) in rows.enumerated() {
            var norm = 0.0
            for (_, d) in row.g { norm += d * d }
            norm = norm.squareRoot()
            let k = norm > 1e-14 ? 1 / norm : 0
            for (i, d) in row.g { a[Int(i) + j * n] = d * k }
            rhs[j] = -row.v * k
        }

        var perm = Array(0..<m)
        var colNorm = (0..<m).map { j -> Double in
            var s = 0.0
            for i in 0..<n { s += a[i + j * n] * a[i + j * n] }
            return s
        }
        var betas: [Double] = []
        var vectors: [[Double]] = []
        var diag: [Double] = []
        var rank = 0
        let limit = min(n, m)
        let rankTolerance = 1e-9

        for k in 0..<limit {
            // Pivot: bring the column with the largest remaining norm to position k.
            var best = k
            for j in k..<m where colNorm[j] > colNorm[best] { best = j }
            if colNorm[best].squareRoot() <= rankTolerance { break }
            if best != k {
                for i in 0..<n { a.swapAt(i + k * n, i + best * n) }
                colNorm.swapAt(k, best)
                perm.swapAt(k, best)
            }
            // Householder reflection zeroing column k below the diagonal.
            var sigma = 0.0
            for i in k..<n { sigma += a[i + k * n] * a[i + k * n] }
            let norm = sigma.squareRoot()
            let alpha = a[k + k * n] > 0 ? -norm : norm
            var v = [Double](repeating: 0, count: n)
            for i in k..<n { v[i] = a[i + k * n] }
            v[k] -= alpha
            var vv = 0.0
            for i in k..<n { vv += v[i] * v[i] }
            let beta = vv > 0 ? 2 / vv : 0
            for j in k..<m {
                var dotted = 0.0
                for i in k..<n { dotted += v[i] * a[i + j * n] }
                let f = beta * dotted
                if f != 0 { for i in k..<n { a[i + j * n] -= f * v[i] } }
            }
            for j in (k + 1)..<max(k + 1, m) {
                var s = 0.0
                for i in (k + 1)..<max(k + 1, n) { s += a[i + j * n] * a[i + j * n] }
                colNorm[j] = s
            }
            betas.append(beta)
            vectors.append(v)
            diag.append(a[k + k * n])
            rank += 1
        }

        // Solve Rᵀy = (Pᵀ·rhs) by forward substitution, then dx = Q·y.
        var y = [Double](repeating: 0, count: n)
        for k in 0..<rank {
            var s = rhs[perm[k]]
            for i in 0..<k { s -= a[i + k * n] * y[i] }
            y[k] = s / a[k + k * n]
        }
        func applyQ(_ w: inout [Double]) {
            for k in stride(from: rank - 1, through: 0, by: -1) {
                var dotted = 0.0
                for i in k..<n { dotted += vectors[k][i] * w[i] }
                let f = betas[k] * dotted
                if f != 0 { for i in k..<n { w[i] -= f * vectors[k][i] } }
            }
        }
        applyQ(&y)

        var free = [Bool](repeating: false, count: n)
        if wantNullSpace {
            // Q's columns past the rank span the null space of J: the directions the sketch can still move.
            for col in rank..<max(rank, n) {
                var e = [Double](repeating: 0, count: n)
                e[col] = 1
                applyQ(&e)
                for i in 0..<n where abs(e[i]) > 1e-8 { free[i] = true }
            }
        }
        return Factored(step: y, rank: rank, dependentRows: rank < m ? Array(perm[rank...]) : [], freeVariables: free)
    }

    // MARK: Dragging

    /// Drags a point towards `target`, re-solving around it. If the point can't reach it, the sketch is
    /// left unchanged and false is returned.
    @discardableResult
    public static func drag(_ sketch: inout Sketch2D, point: Int, to target: Vec2) -> Bool {
        guard point != Sketch2D.originID else { return false }
        var trial = sketch
        trial.setPosition(point, target)
        let result = solve(&trial, pinned: [point])
        guard result.converged else { return false }
        sketch = trial
        return true
    }

    /// Drags a circle's radius.
    @discardableResult
    public static func drag(_ sketch: inout Sketch2D, radiusOf curve: Int, to radius: Double) -> Bool {
        guard radius > 0, let i = sketch.curves.firstIndex(where: { $0.id == curve }),
              case .circle(let center, _) = sketch.curves[i].geometry else { return false }
        var trial = sketch
        trial.curves[i].geometry = .circle(center: center, radius: radius)
        guard solve(&trial, pinnedRadii: [curve]).converged else { return false }
        sketch = trial
        return true
    }
}
