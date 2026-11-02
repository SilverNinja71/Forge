import Foundation
import simd

/// A permanent reference to an edge: the two named faces it runs between. Because face names survive
/// re-computation, a fillet still finds its edge after an upstream dimension changes.
public struct EdgeRef: Codable, Hashable, Sendable {
    public var a: FaceTag
    public var b: FaceTag
    /// Where the edge was when picked. If a pair of faces meets along several separate runs, the nearest wins.
    public var hint: Vec3?

    public init(a: FaceTag, b: FaceTag, hint: Vec3? = nil) {
        self.a = a
        self.b = b
        self.hint = hint
    }

    func joins(_ x: FaceTag, _ y: FaceTag) -> Bool { (x == a && y == b) || (x == b && y == a) }
}

extension Solid {
    /// Edges between two named faces, as a list of edge indices.
    func edgeIndices(for ref: EdgeRef) -> [Int] {
        edges.indices.filter { i in
            let e = edges[i]
            return e.f1 >= 0 && ref.joins(faces[Int(e.f0)].tag, faces[Int(e.f1)].tag)
        }
    }

    /// The tag pair of an edge, as a reference with a hint at its midpoint.
    public func reference(toEdge index: Int) -> EdgeRef? {
        guard edges.indices.contains(index) else { return nil }
        let e = edges[index]
        guard e.f1 >= 0 else { return nil }
        return EdgeRef(a: faces[Int(e.f0)].tag, b: faces[Int(e.f1)].tag,
                       hint: (positions[Int(e.a)] + positions[Int(e.b)]) / 2)
    }

    /// Edges of a chain are found by walking from `index` through other edges between the same pair of faces.
    public func chain(containing index: Int) -> [Int] {
        guard let ref = reference(toEdge: index) else { return [index] }
        let all = edgeIndices(for: ref)
        var byVertex: [Int32: [Int]] = [:]
        for i in all {
            byVertex[edges[i].a, default: []].append(i)
            byVertex[edges[i].b, default: []].append(i)
        }
        var seen: Set<Int> = [index]
        var stack = [index]
        while let i = stack.popLast() {
            for v in [edges[i].a, edges[i].b] {
                for j in byVertex[v] ?? [] where seen.insert(j).inserted { stack.append(j) }
            }
        }
        return seen.sorted()
    }
}

/// Rounds or bevels edges by building a tool solid along the edge and cutting it away from a convex edge,
/// or adding it to a concave one.
public enum FilletOp {
    public enum Shape: Equatable, Sendable {
        case fillet(radius: Double)
        /// Set-backs along each face, measured from the edge.
        case chamfer(d1: Double, d2: Double)
        /// Set-back along the first face plus the angle the bevel makes with that face.
        case chamferAngle(distance: Double, angle: Double)
    }

    /// One vertex of a chain: the edge position and the two face directions there.
    struct Station {
        var p: Vec3
        var tangent: Vec3
        var n0: Vec3
        var n1: Vec3
        var u0: Vec3
        var u1: Vec3
    }

    struct Chain {
        var stations: [Station]
        var closed: Bool
        var tagA: FaceTag
        var tagB: FaceTag
    }

    /// Finds the runs of connected edges that a set of references selects.
    static func chains(_ solid: Solid, refs: [EdgeRef]) throws -> [Chain] {
        var edgeIDs = Set<Int>()
        for ref in refs {
            let found = solid.edgeIndices(for: ref)
            guard !found.isEmpty else { continue }
            if let hint = ref.hint {
                // Choose the connected run nearest to the point where it was picked.
                var remaining = Set(found)
                var runs: [[Int]] = []
                while let first = remaining.first {
                    let run = solid.chain(containing: first).filter { found.contains($0) }
                    remaining.subtract(run)
                    runs.append(run.isEmpty ? [first] : run)
                    if run.isEmpty { remaining.remove(first) }
                }
                let distance: ([Int]) -> Double = { run in
                    run.map { i -> Double in
                        let e = solid.edges[i]
                        let (p, _) = closestPoints(solid.positions[Int(e.a)], solid.positions[Int(e.b)], hint, hint)
                        return simd_length(p - hint)
                    }.min() ?? .infinity
                }
                if let best = runs.min(by: { distance($0) < distance($1) }) { edgeIDs.formUnion(best) }
            } else {
                edgeIDs.formUnion(found)
            }
        }
        guard !edgeIDs.isEmpty else { throw FeatureError("The edge this feature used no longer exists") }

        // Connect edges at shared vertices, but only where the chain continues smoothly.
        struct Directed {
            var from: Int32, to: Int32
            var n0: Vec3, n1: Vec3
            var u0: Vec3, u1: Vec3
            var tagA: FaceTag, tagB: FaceTag
        }
        var pieces: [Int: Directed] = [:]
        for i in edgeIDs {
            let e = solid.edges[i]
            // f0 walks a → b inside its own loop. Interior of a face lies to the left of its walking direction.
            let f0 = solid.faces[Int(e.f0)], f1 = solid.faces[Int(e.f1)]
            let d = simd_normalize(solid.positions[Int(e.b)] - solid.positions[Int(e.a)])
            let u0 = simd_cross(f0.plane.normal, d)
            let u1 = simd_cross(f1.plane.normal, -d)
            pieces[i] = Directed(from: e.a, to: e.b, n0: f0.plane.normal, n1: f1.plane.normal, u0: u0, u1: u1, tagA: f0.tag, tagB: f1.tag)
        }
        var byVertex: [Int32: [Int]] = [:]
        for (i, p) in pieces {
            byVertex[p.from, default: []].append(i)
            byVertex[p.to, default: []].append(i)
        }
        var unused = Set(pieces.keys)
        var result: [Chain] = []

        func direction(_ i: Int, startingAt v: Int32) -> Vec3 {
            let p = pieces[i]!
            let other = p.from == v ? p.to : p.from
            return simd_normalize(solid.positions[Int(other)] - solid.positions[Int(v)])
        }
        func continuation(of i: Int, at v: Int32) -> Int? {
            let incoming = -direction(i, startingAt: v)
            var best: Int?
            var bestDot = cos(40 * Double.pi / 180)
            for j in byVertex[v] ?? [] where j != i && unused.contains(j) {
                let d = simd_dot(incoming, direction(j, startingAt: v))
                if d > bestDot {
                    bestDot = d
                    best = j
                }
            }
            return best
        }

        while let first = unused.sorted().first {
            unused.remove(first)
            // Walk forward from `first`, then backward, collecting (edge, startVertex).
            var forward: [(Int, Int32)] = [(first, pieces[first]!.from)]
            var v = pieces[first]!.to
            var current = first
            var closed = false
            while let j = continuation(of: current, at: v) {
                unused.remove(j)
                forward.append((j, v))
                v = pieces[j]!.from == v ? pieces[j]!.to : pieces[j]!.from
                current = j
            }
            if v == forward[0].1, forward.count > 2 {
                closed = true
            } else {
                var back: [(Int, Int32)] = []
                var u = forward[0].1
                var cur = first
                while let j = continuation(of: cur, at: u) {
                    unused.remove(j)
                    let next = pieces[j]!.from == u ? pieces[j]!.to : pieces[j]!.from
                    back.append((j, next))
                    u = next
                    cur = j
                }
                forward = back.reversed() + forward
            }

            // Build a station at each vertex, averaging the faces either side so a many-sided curve stays symmetric.
            let frontDirection = { (i: Int, v: Int32) -> (Vec3, Vec3, Vec3, Vec3, Vec3) in
                let p = pieces[i]!
                let walkingForward = p.from == v
                let t = simd_normalize(solid.positions[Int(p.to)] - solid.positions[Int(p.from)]) * (walkingForward ? 1 : -1)
                // Keep the two faces in a consistent order along the chain: A stays A.
                return (t, p.n0, p.n1, p.u0, p.u1)
            }
            let vertices: [Int32] = {
                var vs = forward.map(\.1)
                if !closed {
                    let last = forward.last!
                    let p = pieces[last.0]!
                    vs.append(p.from == last.1 ? p.to : p.from)
                }
                return vs
            }()
            let count = forward.count
            var stations: [Station] = []
            let refTag = pieces[forward[0].0]!.tagA
            func oriented(_ i: Int) -> (t: Vec3, n0: Vec3, n1: Vec3, u0: Vec3, u1: Vec3) {
                let start = forward[i].1
                var (t, n0, n1, u0, u1) = frontDirection(forward[i].0, start)
                if pieces[forward[i].0]!.tagA != refTag { swap(&n0, &n1); swap(&u0, &u1) }
                _ = t
                t = direction(forward[i].0, startingAt: start)
                return (t, n0, n1, u0, u1)
            }
            for (k, vertex) in vertices.enumerated() {
                let before = closed ? oriented((k + count - 1) % count) : (k > 0 ? oriented(k - 1) : nil)
                let after = closed ? oriented(k % count) : (k < count ? oriented(k) : nil)
                let parts = [before, after].compactMap { $0 }
                func mean(_ f: ((t: Vec3, n0: Vec3, n1: Vec3, u0: Vec3, u1: Vec3)) -> Vec3) -> Vec3 {
                    simd_normalize(parts.map(f).reduce(Vec3.zero, +))
                }
                let t = mean { $0.t }, n0 = mean { $0.n0 }, n1 = mean { $0.n1 }
                // Directions into each face, perpendicular to the averaged edge direction.
                var u0 = simd_cross(n0, t), u1 = simd_cross(n1, t)
                if simd_dot(u0, parts[0].u0) < 0 { u0 = -u0 }
                if simd_dot(u1, parts[0].u1) < 0 { u1 = -u1 }
                stations.append(Station(p: solid.positions[Int(vertex)], tangent: t, n0: n0, n1: n1, u0: u0, u1: u1))
            }
            let p0 = pieces[forward[0].0]!
            result.append(Chain(stations: stations, closed: closed, tagA: p0.tagA, tagB: p0.tagB))
        }
        return result
    }

    /// Applies a fillet or chamfer to edges of `solid`. All tools are measured against the original
    /// solid, then applied in turn: where fillets meet at a corner, their surfaces intersect in a mitre.
    public static func apply(to solid: Solid, refs: [EdgeRef], shape: Shape, feature: Int) throws -> Solid {
        let chains = try chains(solid, refs: refs)
        var tools: [(tool: Solid, op: CSG.Operation)] = []
        for (index, chain) in chains.enumerated() {
            let (tool, isConvex) = try buildTool(chain: chain, solid: solid, shape: shape, feature: feature, index: index)
            tools.append((tool, isConvex ? .subtract : .union))
        }
        var result = solid
        // Remove material first, then add, so an added fillet can't be cut by a neighbour's tool.
        for t in tools where t.op == .subtract { result = CSG.combine(result, t.tool, .subtract) }
        for t in tools where t.op == .union { result = CSG.combine(result, t.tool, .union) }
        guard !result.isEmpty else { throw FeatureError("That removed the whole body") }
        return result
    }

    private static func buildTool(chain: Chain, solid: Solid, shape: Shape, feature: Int, index: Int) throws -> (Solid, Bool) {
        // Convex when each face lies behind the other's plane.
        let convexScore = chain.stations.reduce(0.0) { $0 + simd_dot($1.u0, $1.n1) }
        let isConvex = convexScore < 0

        let tag: FaceTag
        switch shape {
        case .fillet: tag = FaceTag(feature: feature, role: .fillet, entity: index)
        default: tag = FaceTag(feature: feature, role: .chamfer, entity: index)
        }

        // Cross-section at each station: first the curve, then outer points beyond the surface.
        struct Section {
            var band: [MeshVertex]
            var outer: [Vec3]
        }
        // The tool reaches slightly past the surface so its side walls don't sit exactly on the faces. Just slightly:
        // on a small circular edge a long reach would pass through the axis and turn the ring inside out.
        let size: Double
        switch shape {
        case .fillet(let r): size = r
        case .chamfer(let d1, let d2): size = max(d1, d2)
        case .chamferAngle(let d, _): size = d
        }
        let margin = min(max(size * 0.2, 0.02), 1)
        var sections: [Section] = []
        var reach = 0.0
        let arcSteps: Int = {
            if case .fillet(let r) = shape {
                return max(4, Int((Double(circleSegments(radius: r)) / 4).rounded(.up)))
            }
            return 1
        }()

        for s in chain.stations {
            // Interior angle between the two faces, on the material side.
            let cosT = min(1, max(-1, simd_dot(s.u0, s.u1)))
            let theta = acos(cosT)
            guard theta > 1e-3, theta < .pi - 1e-3 else { throw FeatureError("These faces are nearly flat here, so there's no edge to round") }
            var t0: Vec3, t1: Vec3
            var band: [MeshVertex] = []
            let bisector = simd_normalize(s.u0 + s.u1)
            switch shape {
            case .fillet(let r):
                guard r > 0 else { throw FeatureError("The fillet radius must be above zero") }
                let along = r / tan(theta / 2)
                reach = max(reach, along)
                t0 = s.p + s.u0 * along
                t1 = s.p + s.u1 * along
                let c = s.p + bisector * (r / sin(theta / 2))
                let sweep = .pi - theta
                // Rotating about the edge from t0's radius toward t1's.
                let r0 = (t0 - c) / r, r1 = (t1 - c) / r
                let perp = simd_normalize(r1 - r0 * simd_dot(r1, r0))
                for k in 0...arcSteps {
                    let a = sweep * Double(k) / Double(arcSteps)
                    let dir = r0 * cos(a) + perp * sin(a)
                    // The tool's skin faces the ball centre; after the cut, this is the fillet's outward normal flipped back.
                    band.append(MeshVertex(c + dir * r, -dir))
                }
            case .chamfer(let d1, let d2):
                guard d1 > 0, d2 > 0 else { throw FeatureError("The chamfer distances must be above zero") }
                reach = max(reach, max(d1, d2))
                t0 = s.p + s.u0 * d1
                t1 = s.p + s.u1 * d2
                let n = simd_normalize(simd_cross(t1 - t0, s.tangent))
                let nToward = simd_dot(n, bisector) > 0 ? n : -n
                band = [MeshVertex(t0, nToward), MeshVertex(t1, nToward)]
            case .chamferAngle(let d, let alpha):
                guard d > 0, alpha > 0, alpha < .pi - theta else { throw FeatureError("That chamfer angle doesn't fit between these faces") }
                let d2 = d * sin(alpha) / sin(.pi - theta - alpha)
                reach = max(reach, max(d, d2))
                t0 = s.p + s.u0 * d
                t1 = s.p + s.u1 * d2
                let n = simd_normalize(simd_cross(t1 - t0, s.tangent))
                let nToward = simd_dot(n, bisector) > 0 ? n : -n
                band = [MeshVertex(t0, nToward), MeshVertex(t1, nToward)]
            }
            let sign = isConvex ? 1.0 : -1.0
            let m = margin * sign
            let o1 = t1 + s.n1 * m, o0 = t0 + s.n0 * m
            let corner = s.p + (s.n0 + s.n1) * m
            sections.append(Section(band: band, outer: [o1, corner, o0]))
        }

        // Too-large checks: the setback must land on the faces the edge belongs to.
        func checkLands(_ section: Section) throws {
            for (point, tag) in [(section.band.first!.p, chain.tagA), (section.band.last!.p, chain.tagB)] {
                if solid.distance(from: point, toFacesTagged: tag) > 1e-4 {
                    switch shape {
                    case .fillet: throw FeatureError("The fillet radius is too large for the faces next to this edge")
                    default: throw FeatureError("The chamfer distance is too large for the faces next to this edge")
                    }
                }
            }
        }
        for s in [sections.first!, sections[sections.count / 2], sections.last!] { try checkLands(s) }

        // A cutting tool on an open chain runs past each end when that's empty space, so it cuts cleanly through.
        // A concave fillet adds material, so it must stop exactly at the end of the edge.
        var stations = chain.stations
        if !chain.closed, isConvex {
            let extend = reach * 2 + margin * 2
            func probe(_ s: Station, _ dir: Vec3) -> Bool {
                let inward = simd_normalize(s.u0 + s.u1) * max(reach * 0.25, 1e-3)
                return !solid.contains(s.p + dir * max(reach * 0.25, 1e-3) + inward)
            }
            if let last = stations.last, probe(last, last.tangent) {
                let shift = last.tangent * extend
                var copy = last
                copy.p += shift
                stations.append(copy)
                let end = sections.last!
                sections.append(Section(band: end.band.map { MeshVertex($0.p + shift, $0.n) }, outer: end.outer.map { $0 + shift }))
            }
            if let first = stations.first, probe(first, -first.tangent) {
                let shift = -first.tangent * extend
                var copy = first
                copy.p += shift
                stations.insert(copy, at: 0)
                let start = sections.first!
                sections.insert(Section(band: start.band.map { MeshVertex($0.p + shift, $0.n) }, outer: start.outer.map { $0 + shift }), at: 0)
            }
        }

        // Skin the sections.
        var polys: [Polygon3] = []
        let bandCount = sections[0].band.count
        let outerCount = sections[0].outer.count
        let ringSize = bandCount + outerCount
        let spans = chain.closed ? sections.count : sections.count - 1
        for k in 0..<spans {
            let a = sections[k], b = sections[(k + 1) % sections.count]
            for i in 0..<(bandCount - 1) {
                if let p = Polygon3(smooth: [a.band[i], b.band[i], b.band[i + 1], a.band[i + 1]], tag: tag) { polys.append(p) }
            }
            let ringA = a.band.map(\.p) + a.outer, ringB = b.band.map(\.p) + b.outer
            for i in (bandCount - 1)..<ringSize {
                let j = (i + 1) % ringSize
                if let p = Polygon3(flat: [ringA[i], ringB[i], ringB[j], ringA[j]], tag: tag) { polys.append(p) }
            }
        }
        if !chain.closed {
            func cap(_ section: Section, flip: Bool) {
                let ring = section.band.map(\.p) + section.outer
                guard let plane = Plane3.fit(ring) else { return }
                let frame = Frame3.on(plane: plane, near: ring[0])
                let flat = ring.map { frame.local($0) }
                let ccw = signedArea(flat) > 0
                let ordered = ccw ? flat : flat.reversed()
                let world = ccw ? ring : ring.reversed()
                let tris = Triangulator.triangulate(outer: ordered)
                var i = 0
                while i + 2 < tris.count {
                    let tri = [world[Int(tris[i])], world[Int(tris[i + 1])], world[Int(tris[i + 2])]]
                    let reverse = flip != ccw
                    if let p = Polygon3(flat: reverse ? tri : tri.reversed(), tag: tag) { polys.append(p) }
                    i += 3
                }
            }
            cap(sections.first!, flip: false)
            cap(sections.last!, flip: true)
        }
        let attempt = Solid(polygons: polys)
        let solidTool = attempt.massProperties().volume < 0 ? Solid(polygons: polys.map(\.flippedWindingOnly)) : attempt
        guard solidTool.isClosed, solidTool.massProperties().volume > 0 else {
            throw FeatureError("This edge's shape is too complex to round with this size")
        }
        return (solidTool, isConvex)
    }
}

extension Polygon3 {
    /// Reverses the winding only: band normals were set explicitly and are already right.
    var flippedWindingOnly: Polygon3 {
        Polygon3(verts: verts.reversed(), plane: plane.flipped, tag: tag)
    }
}

/// Hollows a solid, leaving walls of the given thickness and opening the chosen faces.
public enum ShellOp {
    /// Moves every face inward by the thickness (faces being removed move outward instead, so the cavity breaks
    /// through them) and subtracts that offset solid.
    public static func apply(to solid: Solid, removing open: Set<FaceTag>, thickness: Double, feature: Int) throws -> Solid {
        guard thickness > 0 else { throw FeatureError("The wall thickness must be above zero") }
        let outward = max(thickness, 1)
        // For each vertex, solve for the move that satisfies all its face offsets (least squares with light damping).
        var ata = [simd_double3x3](repeating: simd_double3x3(0), count: solid.positions.count)
        var atb = [Vec3](repeating: .zero, count: solid.positions.count)
        var seen = [Set<SIMD4<Int64>>](repeating: [], count: solid.positions.count)
        for f in solid.faces {
            let offset = open.contains(f.tag) ? outward : -thickness
            let n = f.plane.normal
            let key = SIMD4<Int64>(Int64((n.x * 1e6).rounded()), Int64((n.y * 1e6).rounded()), Int64((n.z * 1e6).rounded()), Int64(offset * 1e6))
            for v in f.verts where seen[Int(v)].insert(key).inserted {
                ata[Int(v)] += simd_double3x3(rows: [n * n.x, n * n.y, n * n.z])
                atb[Int(v)] += n * offset
            }
        }
        var moved = solid.positions
        for i in moved.indices {
            let damped = ata[i] + simd_double3x3(diagonal: Vec3(repeating: 1e-9))
            moved[i] += damped.inverse * atb[i]
        }
        var polys: [Polygon3] = []
        let unique = Array(solid.tags).sorted { ($0.feature, $0.role.rawValue, $0.entity) < ($1.feature, $1.role.rawValue, $1.entity) }
        let tagIndex = Dictionary(uniqueKeysWithValues: unique.enumerated().map { ($1, $0) })
        for f in solid.faces {
            let tag = FaceTag(feature: feature, role: .shellInner, entity: tagIndex[f.tag] ?? 0)
            var i = 0
            while i + 2 < f.triangles.count {
                let a = Int(f.triangles[i]), b = Int(f.triangles[i + 1]), c = Int(f.triangles[i + 2])
                let verts = [MeshVertex(moved[Int(f.verts[a])], f.normals[a]),
                             MeshVertex(moved[Int(f.verts[b])], f.normals[b]),
                             MeshVertex(moved[Int(f.verts[c])], f.normals[c])]
                if let p = Polygon3(smooth: verts, tag: tag) {
                    // A triangle that flipped over means the offset turned the face inside out.
                    if simd_dot(p.plane.normal, f.plane.normal) < 0 {
                        throw FeatureError("The wall thickness is too large for this body")
                    }
                    polys.append(Polygon3(verts: verts, plane: p.plane, tag: tag))
                }
                i += 3
            }
        }
        let inner = Solid(polygons: polys)
        guard inner.massProperties().volume > 0 else { throw FeatureError("The wall thickness is too large for this body") }
        let result = CSG.combine(solid, inner, .subtract)
        guard !result.isEmpty else { throw FeatureError("Shelling removed the whole body") }
        return result
    }
}
