import Foundation
import simd

/// One straight piece of a profile boundary, remembering which sketch curve it came from.
public struct ProfileEdge: Equatable, Sendable {
    public var a: Vec2
    public var b: Vec2
    public var curve: Int
    /// Unit outward normals of the true curve at each end (radial for arcs); nil on straight lines.
    public var smoothNormals: (a: Vec2, b: Vec2)?

    public static func == (l: ProfileEdge, r: ProfileEdge) -> Bool { l.a == r.a && l.b == r.b && l.curve == r.curve }
}

public struct ProfileLoop: Equatable, Sendable {
    public var edges: [ProfileEdge]
    public var points: [Vec2] { edges.map(\.a) }
    public var area: Double { signedArea(points) }
}

/// A closed area of a sketch that can be extruded: one counter-clockwise outer loop and clockwise holes.
public struct ProfileRegion: Equatable, Sendable {
    public var outer: ProfileLoop
    public var holes: [ProfileLoop]
    /// How many other regions this one is nested inside. Even-depth regions are what you usually want:
    /// extruding a plate with a hole leaves the hole empty.
    public var depth = 0
    public var area: Double { outer.area + holes.reduce(0) { $0 + $1.area } }
    /// Identifies the region across edits: the sketch curves around it.
    public var key: [Int] {
        Array(Set(outer.edges.map(\.curve) + holes.flatMap { $0.edges.map(\.curve) })).sorted()
    }

    func contains(_ p: Vec2) -> Bool {
        pointInLoop(p, outer.points) && !holes.contains { pointInLoop(p, $0.points) }
    }

    /// Triangles covering the region, as indices into `allPoints`.
    public var allPoints: [Vec2] { outer.points + holes.flatMap(\.points) }
    public func triangles() -> [Int32] {
        Triangulator.triangulate(outer: outer.points, holes: holes.map(\.points))
    }
}

extension Sketch2D {
    /// Straight pieces of every drawn (non-construction) curve.
    func tessellatedEdges(includeConstruction: Bool = false) -> [ProfileEdge] {
        var edges: [ProfileEdge] = []
        for c in curves where includeConstruction || !c.isConstruction {
            switch c.geometry {
            case .line(let a, let b):
                let pa = position(a), pb = position(b)
                if simd_length(pb - pa) > 1e-9 { edges.append(ProfileEdge(a: pa, b: pb, curve: c.id, smoothNormals: nil)) }
            case .circle(let center, let r):
                edges += arcEdges(center: position(center), radius: r, from: 0, sweep: 2 * .pi, curve: c.id)
            case .arc(let center, let s, let e):
                let cp = position(center), ps = position(s), pe = position(e)
                let r = simd_length(ps - cp)
                let a0 = atan2(ps.y - cp.y, ps.x - cp.x), a1 = atan2(pe.y - cp.y, pe.x - cp.x)
                var sweep = a1 - a0
                if sweep <= 1e-9 { sweep += 2 * .pi }
                var pieces = arcEdges(center: cp, radius: r, from: a0, sweep: sweep, curve: c.id)
                // End exactly on the sketch points so joined curves weld cleanly.
                if !pieces.isEmpty {
                    pieces[0].a = ps
                    pieces[pieces.count - 1].b = pe
                }
                edges += pieces
            }
        }
        return edges
    }

    private func arcEdges(center: Vec2, radius r: Double, from a0: Double, sweep: Double, curve: Int) -> [ProfileEdge] {
        let total = circleSegments(radius: r)
        let n = max(2, Int((Double(total) * sweep / (2 * .pi)).rounded(.up)))
        var out: [ProfileEdge] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let t0 = a0 + sweep * Double(i) / Double(n), t1 = a0 + sweep * Double(i + 1) / Double(n)
            let n0 = Vec2(cos(t0), sin(t0)), n1 = Vec2(cos(t1), sin(t1))
            out.append(ProfileEdge(a: center + n0 * r, b: center + n1 * r, curve: curve, smoothNormals: (n0, n1)))
        }
        return out
    }

    /// Finds every closed region in the drawing, including regions formed where curves cross.
    ///
    /// Curves become straight edges, edges are split where they meet, and the resulting planar graph is walked
    /// always turning as far left as possible, which traces each enclosed area exactly once.
    public func regions() -> [ProfileRegion] {
        let raw = tessellatedEdges()
        guard !raw.isEmpty else { return [] }

        // Split edges where they cross or touch.
        var cuts = [[Double]](repeating: [], count: raw.count)
        let eps = 1e-7
        for i in raw.indices {
            let a = raw[i].a, r = raw[i].b - a
            for j in (i + 1)..<max(i + 1, raw.count) {
                let c = raw[j].a, s = raw[j].b - c
                // Quick reject on bounding boxes.
                if max(a.x, a.x + r.x) + eps < min(c.x, c.x + s.x) || max(c.x, c.x + s.x) + eps < min(a.x, a.x + r.x)
                    || max(a.y, a.y + r.y) + eps < min(c.y, c.y + s.y) || max(c.y, c.y + s.y) + eps < min(a.y, a.y + r.y) { continue }
                let denom = r.cross(s)
                if abs(denom) < 1e-14 { continue }
                let t = (c - a).cross(s) / denom, u = (c - a).cross(r) / denom
                let rl = r.length, sl = s.length
                guard t > -eps / rl, t < 1 + eps / rl, u > -eps / sl, u < 1 + eps / sl else { continue }
                if t > eps / rl, t < 1 - eps / rl { cuts[i].append(t) }
                if u > eps / sl, u < 1 - eps / sl { cuts[j].append(u) }
            }
        }

        // Weld end points into graph nodes.
        var nodes: [Vec2] = []
        var buckets: [SIMD2<Int64>: [Int]] = [:]
        func node(_ p: Vec2) -> Int {
            let cell = SIMD2<Int64>(Int64((p.x / 1e-6).rounded(.down)), Int64((p.y / 1e-6).rounded(.down)))
            for dx in -1...1 {
                for dy in -1...1 {
                    for i in buckets[cell &+ SIMD2(Int64(dx), Int64(dy))] ?? [] where simd_length(nodes[i] - p) < 1e-6 { return i }
                }
            }
            nodes.append(p)
            buckets[cell, default: []].append(nodes.count - 1)
            return nodes.count - 1
        }

        struct HalfEdge {
            var from: Int, to: Int
            var edge: ProfileEdge
            var used = false
        }
        var halves: [HalfEdge] = []
        var seen = Set<SIMD2<Int>>()
        for (i, e) in raw.enumerated() {
            let ts = [0.0] + cuts[i].sorted() + [1.0]
            for k in 0..<(ts.count - 1) {
                let pa = e.a + (e.b - e.a) * ts[k], pb = e.a + (e.b - e.a) * ts[k + 1]
                let na = node(pa), nb = node(pb)
                guard na != nb else { continue }
                // Overlapping drawn lines produce one graph edge, not two.
                guard seen.insert(SIMD2(min(na, nb), max(na, nb))).inserted else { continue }
                var smooth = e.smoothNormals
                if let s = smooth, ts.count > 2 {
                    let mix0 = simd_normalize(s.a + (s.b - s.a) * ts[k]), mix1 = simd_normalize(s.a + (s.b - s.a) * ts[k + 1])
                    smooth = (mix0, mix1)
                }
                let piece = ProfileEdge(a: nodes[na], b: nodes[nb], curve: e.curve, smoothNormals: smooth)
                let back = ProfileEdge(a: nodes[nb], b: nodes[na], curve: e.curve, smoothNormals: smooth.map { ($0.b, $0.a) })
                halves.append(HalfEdge(from: na, to: nb, edge: piece))
                halves.append(HalfEdge(from: nb, to: na, edge: back))
            }
        }

        // Prune dead ends: an open tail can't bound an area.
        var alive = [Bool](repeating: true, count: halves.count)
        var degree = [Int](repeating: 0, count: nodes.count)
        for h in halves { degree[h.from] += 1 }
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < halves.count {
                if alive[i], degree[halves[i].from] == 1 || degree[halves[i].to] == 1 {
                    alive[i] = false
                    alive[i + 1] = false
                    degree[halves[i].from] -= 1
                    degree[halves[i].to] -= 1
                    changed = true
                }
                i += 2
            }
        }

        // Outgoing edges at each node, sorted by direction.
        var outgoing = [[Int]](repeating: [], count: nodes.count)
        for i in halves.indices where alive[i] { outgoing[halves[i].from].append(i) }
        for n in outgoing.indices {
            outgoing[n].sort {
                let da = nodes[halves[$0].to] - nodes[n], db = nodes[halves[$1].to] - nodes[n]
                return atan2(da.y, da.x) < atan2(db.y, db.x)
            }
        }

        var bounded: [ProfileRegion] = []
        var outerBoundaries: [ProfileLoop] = []
        for start in halves.indices where alive[start] && !halves[start].used {
            var loop: [ProfileEdge] = []
            var current = start
            repeat {
                halves[current].used = true
                loop.append(halves[current].edge)
                // Twin is the same edge reversed; pairs are stored adjacent.
                let twin = current ^ 1
                let at = halves[current].to
                let list = outgoing[at]
                let k = list.firstIndex(of: twin)!
                // The next edge clockwise from the way we came keeps the enclosed area on the left.
                current = list[(k + list.count - 1) % list.count]
            } while current != start
            let result = ProfileLoop(edges: loop)
            if result.area > 1e-9 {
                bounded.append(ProfileRegion(outer: result, holes: []))
            } else if result.area < -1e-9 {
                outerBoundaries.append(result)
            }
        }

        // A separate cluster's outer boundary is a hole in the smallest region that contains it.
        for boundary in outerBoundaries {
            guard let probe = boundary.edges.first?.a else { continue }
            var best: Int?
            for (i, r) in bounded.enumerated() where r.outer.area > -boundary.area {
                guard pointInLoop(probe, r.outer.points), !r.outer.edges.contains(where: { simd_length($0.a - probe) < 1e-6 }) else { continue }
                if best == nil || r.outer.area < bounded[best!].outer.area { best = i }
            }
            if let best { bounded[best].holes.append(boundary) }
        }

        // Nesting depth: how many other outer loops surround this region.
        for i in bounded.indices {
            guard let probe = interiorPoint(of: bounded[i]) else { continue }
            var depth = 0
            for j in bounded.indices where j != i && bounded[j].outer.area > bounded[i].outer.area {
                if pointInLoop(probe, bounded[j].outer.points) { depth += 1 }
            }
            bounded[i].depth = depth
        }
        return bounded.sorted { $0.area > $1.area }
    }

    /// A point strictly inside a region (the centre of its largest triangle).
    func interiorPoint(of region: ProfileRegion) -> Vec2? {
        let pts = region.allPoints, tris = region.triangles()
        var best: Vec2?
        var bestArea = 0.0
        var i = 0
        while i + 2 < tris.count {
            let a = pts[Int(tris[i])], b = pts[Int(tris[i + 1])], c = pts[Int(tris[i + 2])]
            let area = abs((b - a).cross(c - a))
            if area > bestArea {
                bestArea = area
                best = (a + b + c) / 3
            }
            i += 3
        }
        return best
    }
}
