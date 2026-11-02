import Foundation
import simd

/// A permanent name for a face, independent of how the model is cut up later. It records which feature
/// made the face and what role it plays there (the side grown from sketch line 7, the end cap…).
/// This is how fillets keep finding "their" edge after an earlier sketch dimension changes.
public struct FaceTag: Hashable, Codable, Sendable {
    public enum Role: UInt8, Codable, Sendable {
        case side, startCap, endCap, fillet, chamfer, shellInner, loftSide
    }

    public var feature: Int32
    public var role: Role
    public var entity: Int32

    public init(feature: Int, role: Role, entity: Int = 0) {
        self.feature = Int32(feature)
        self.role = role
        self.entity = Int32(entity)
    }
}

public struct MeshVertex: Sendable {
    public var p: Vec3
    /// Shading normal: the true curved-surface normal, so a 64-sided cylinder still looks round.
    public var n: Vec3

    public init(_ p: Vec3, _ n: Vec3) {
        self.p = p
        self.n = n
    }
}

/// One planar polygon as used while building solids and running booleans.
public struct Polygon3: Sendable {
    public var verts: [MeshVertex]
    public var plane: Plane3
    public var tag: FaceTag

    public init(verts: [MeshVertex], plane: Plane3, tag: FaceTag) {
        self.verts = verts
        self.plane = plane
        self.tag = tag
    }

    /// A polygon whose shading normals equal its plane normal. Nil when it has no area.
    public init?(flat points: [Vec3], tag: FaceTag) {
        guard let plane = Plane3.fit(points) else { return nil }
        self.init(verts: points.map { MeshVertex($0, plane.normal) }, plane: plane, tag: tag)
    }

    /// A polygon with explicit shading normals. Nil when it has no area.
    public init?(smooth verts: [MeshVertex], tag: FaceTag) {
        guard let plane = Plane3.fit(verts.map(\.p)) else { return nil }
        self.init(verts: verts, plane: plane, tag: tag)
    }

    public var flipped: Polygon3 {
        Polygon3(verts: verts.reversed().map { MeshVertex($0.p, -$0.n) }, plane: plane.flipped, tag: tag)
    }
}

/// One planar piece of a solid's skin: its outline, its holes and its triangles. A curved surface is a band
/// of many such faces sharing a tag.
public struct SolidFace: Sendable {
    public var tag: FaceTag
    public var plane: Plane3
    /// Solid-wide vertex ids used by this face, with one shading normal each.
    public var verts: [Int32]
    public var normals: [Vec3]
    /// Index ranges into `verts`: the outer boundary first, then holes.
    public var loops: [Range<Int>]
    /// Triples of indices into `verts`.
    public var triangles: [Int32]
}

/// What an edge means for drawing and picking.
public enum EdgeKind: UInt8, Sendable {
    /// A crease: always drawn.
    case sharp
    /// Between different faces that meet smoothly (a fillet's boundary): drawn faintly.
    case tangent
    /// Inside one curved surface, between its flat facets: only drawn where it is the silhouette.
    case smooth
    /// Between coplanar faces of different features: never drawn.
    case seamless
    /// Doesn't have exactly two faces. A valid closed solid has none.
    case open
}

public struct SolidEdge: Sendable {
    public var a: Int32
    public var b: Int32
    public var f0: Int32
    /// -1 on an open edge.
    public var f1: Int32
    public var kind: EdgeKind
}

/// A closed polyhedral boundary-representation (B-Rep) solid: vertices shared between faces, faces with
/// permanent names, and edges that know which two faces they separate.
public struct Solid: Sendable {
    public private(set) var positions: [Vec3] = []
    public private(set) var faces: [SolidFace] = []
    public private(set) var edges: [SolidEdge] = []
    public private(set) var bounds = AABB.empty

    public init() {}

    public var isEmpty: Bool { faces.isEmpty }

    /// True when every edge has exactly two faces: a watertight skin that encloses a volume.
    public var isClosed: Bool { !faces.isEmpty && !edges.contains { $0.kind == .open } }

    public var triangleCount: Int { faces.reduce(0) { $0 + $1.triangles.count / 3 } }

    public var tags: Set<FaceTag> { Set(faces.map(\.tag)) }

    /// Merging tolerance: positions closer than this are the same vertex (a hundredth of a micron).
    static let weldTolerance = 5e-6

    /// Builds a clean solid from a polygon soup: welds vertices, repairs T-junctions, merges coplanar pieces
    /// of the same face back into single outlines and re-triangulates them.
    public init(polygons: [Polygon3]) {
        var welder = VertexWelder()
        struct Raw {
            var loop: [Int32]
            var normals: [Vec3]
            var poly: Int
        }
        var raws: [Raw] = []
        raws.reserveCapacity(polygons.count)
        for (pi, poly) in polygons.enumerated() {
            var loop: [Int32] = []
            var normals: [Vec3] = []
            loop.reserveCapacity(poly.verts.count)
            for v in poly.verts {
                let id = welder.id(for: v.p)
                if loop.last == id { continue }
                loop.append(id)
                normals.append(v.n)
            }
            if loop.count > 1, loop.first == loop.last {
                loop.removeLast()
                normals.removeLast()
            }
            guard loop.count >= 3 else { continue }
            raws.append(Raw(loop: loop, normals: normals, poly: pi))
        }
        positions = welder.positions

        // Repair T-junctions: a long edge on one side, several short ones on the other. Only edges with no
        // opposite partner need looking at, and only vertices at the ends of other such edges can sit on them.
        func unmatchedEdges() -> Set<SIMD2<Int32>> {
            var directed: [SIMD2<Int32>: Int] = [:]
            for r in raws {
                for i in r.loop.indices {
                    directed[SIMD2(r.loop[i], r.loop[(i + 1) % r.loop.count]), default: 0] += 1
                }
            }
            var open = Set<SIMD2<Int32>>()
            for (e, count) in directed where (directed[SIMD2(e.y, e.x)] ?? 0) != count { open.insert(e) }
            return open
        }
        for _ in 0..<3 {
            let open = unmatchedEdges()
            guard !open.isEmpty else { break }
            let candidates = Array(Set(open.flatMap { [$0.x, $0.y] }))
            let positions = positions
            let tol = Self.weldTolerance * 2
            var grid = SpatialGrid(cell: max(AABB(points: candidates.map { positions[Int($0)] }).diagonal / 64, 1e-3))
            for c in candidates { grid.insert(c, at: positions[Int(c)]) }
            var changed = false
            for ri in raws.indices {
                var newLoop: [Int32] = []
                var newNormals: [Vec3] = []
                var touched = false
                let loop = raws[ri].loop
                for i in loop.indices {
                    let a = loop[i], b = loop[(i + 1) % loop.count]
                    newLoop.append(a)
                    newNormals.append(raws[ri].normals[i])
                    guard open.contains(SIMD2(a, b)) else { continue }
                    let pa = positions[Int(a)], pb = positions[Int(b)]
                    let d = pb - pa, len2 = simd_length_squared(d)
                    guard len2 > 0 else { continue }
                    var hits: [(Double, Int32)] = []
                    grid.visit(from: pa, to: pb) { c in
                        guard c != a, c != b else { return }
                        let p = positions[Int(c)]
                        let t = simd_dot(p - pa, d) / len2
                        guard t > 1e-12, t < 1 - 1e-12 else { return }
                        if simd_length(pa + d * t - p) < tol, !hits.contains(where: { $0.1 == c }) { hits.append((t, c)) }
                    }
                    if hits.isEmpty { continue }
                    touched = true
                    let na = raws[ri].normals[i], nb = raws[ri].normals[(i + 1) % loop.count]
                    for (t, c) in hits.sorted(by: { $0.0 < $1.0 }) {
                        newLoop.append(c)
                        newNormals.append(simd_normalize(na + (nb - na) * t))
                    }
                }
                if touched {
                    raws[ri].loop = newLoop
                    raws[ri].normals = newNormals
                    changed = true
                }
            }
            if !changed { break }
        }

        // Group pieces by (tag, plane), then cancel edges shared within a group: what's left is the outline.
        struct Group {
            var tag: FaceTag
            var plane: Plane3
            var raws: [Int] = []
        }
        var groups: [Group] = []
        var groupsByTag: [FaceTag: [Int]] = [:]
        for (ri, r) in raws.enumerated() {
            let poly = polygons[r.poly]
            let list = groupsByTag[poly.tag] ?? []
            if let g = list.first(where: {
                simd_dot(groups[$0].plane.normal, poly.plane.normal) > 1 - 1e-9 && abs(groups[$0].plane.d - poly.plane.d) < 1e-6
            }) {
                groups[g].raws.append(ri)
            } else {
                groupsByTag[poly.tag, default: []].append(groups.count)
                groups.append(Group(tag: poly.tag, plane: poly.plane, raws: [ri]))
            }
        }

        var outlines: [(group: Int, loops: [[Int32]], normalOf: [Int32: Vec3])] = []
        outlines.reserveCapacity(groups.count)
        for (gi, g) in groups.enumerated() {
            var count: [SIMD2<Int32>: Int] = [:]
            var normalOf: [Int32: Vec3] = [:]
            for ri in g.raws {
                let r = raws[ri]
                for i in r.loop.indices {
                    count[SIMD2(r.loop[i], r.loop[(i + 1) % r.loop.count]), default: 0] += 1
                    if normalOf[r.loop[i]] == nil { normalOf[r.loop[i]] = r.normals[i] }
                }
            }
            var next: [Int32: [Int32]] = [:]
            for (e, c) in count {
                let back = count[SIMD2(e.y, e.x)] ?? 0
                if c > back {
                    for _ in 0..<(c - back) { next[e.x, default: []].append(e.y) }
                }
            }
            let loops = Self.chainLoops(next: next, plane: g.plane, positions: positions)
            if !loops.isEmpty { outlines.append((gi, loops, normalOf)) }
        }

        // Drop vertices that only sit part-way along straight edges (left behind by earlier cuts).
        var neighbours: [Int32: Set<Int32>] = [:]
        for o in outlines {
            for loop in o.loops {
                for i in loop.indices {
                    let a = loop[i], b = loop[(i + 1) % loop.count]
                    neighbours[a, default: []].insert(b)
                    neighbours[b, default: []].insert(a)
                }
            }
        }
        var removable = Set<Int32>()
        for (v, ns) in neighbours where ns.count == 2 {
            let list = Array(ns)
            let a = positions[Int(list[0])], b = positions[Int(list[1])], p = positions[Int(v)]
            let d = simd_normalize(b - a)
            if simd_length(simd_cross(p - a, d)) < 1e-7, simd_dot(p - a, d) > 0, simd_dot(b - p, d) > 0 { removable.insert(v) }
        }

        var used = [Int32](repeating: -1, count: positions.count)
        var finalPositions: [Vec3] = []
        func remap(_ v: Int32) -> Int32 {
            if used[Int(v)] < 0 {
                used[Int(v)] = Int32(finalPositions.count)
                finalPositions.append(positions[Int(v)])
            }
            return used[Int(v)]
        }

        faces.reserveCapacity(outlines.count)
        let oldPositions = positions
        for o in outlines {
            let g = groups[o.group]
            let frame = Frame3.on(plane: g.plane, near: g.plane.normal * g.plane.d)
            var flatLoops: [[Int32]] = []
            for loop in o.loops {
                let kept = loop.filter { !removable.contains($0) }
                if kept.count >= 3 { flatLoops.append(kept) } else if loop.count >= 3 { flatLoops.append(loop) }
            }
            // Sort out which loops are outlines and which are holes (a face may have several islands).
            var outers: [(loop: [Int32], pts: [Vec2], holes: [([Int32], [Vec2])])] = []
            var holes: [([Int32], [Vec2])] = []
            for loop in flatLoops {
                let pts = loop.map { frame.local(oldPositions[Int($0)]) }
                let area = signedArea(pts)
                if area > 1e-10 { outers.append((loop, pts, [])) } else if area < -1e-10 { holes.append((loop, pts)) }
            }
            outers.sort { signedArea($0.pts) < signedArea($1.pts) }
            for hole in holes {
                if let i = outers.firstIndex(where: { outer in
                    let probe = hole.1[0]
                    return pointInLoop(probe, outer.pts) || hole.1.contains { pointInLoop($0, outer.pts) }
                }) {
                    outers[i].holes.append(hole)
                }
            }
            for outer in outers {
                var face = SolidFace(tag: g.tag, plane: g.plane, verts: [], normals: [], loops: [], triangles: [])
                let allLoops = [outer.loop] + outer.holes.map(\.0)
                for loop in allLoops {
                    let start = face.verts.count
                    for v in loop {
                        face.verts.append(remap(v))
                        face.normals.append(o.normalOf[v] ?? g.plane.normal)
                    }
                    face.loops.append(start..<face.verts.count)
                }
                face.triangles = Triangulator.triangulate(outer: outer.pts, holes: outer.holes.map(\.1))
                if !face.triangles.isEmpty { faces.append(face) }
            }
        }
        positions = finalPositions
        bounds = AABB(points: positions)
        buildEdges()
    }

    /// Follows outline edges into closed loops. Where two loops touch at a vertex, turning hardest left at
    /// the junction keeps each loop simple.
    private static func chainLoops(next: [Int32: [Int32]], plane: Plane3, positions: [Vec3]) -> [[Int32]] {
        var next = next
        var loops: [[Int32]] = []
        let frame = Frame3.on(plane: plane, near: plane.normal * plane.d)
        // Deterministic start order: the same input always gives the same output.
        for start in next.keys.sorted() {
            while let first = next[start]?.first {
                var loop: [Int32] = [start]
                var previous = start
                var current = first
                next[start]!.removeFirst()
                var guardCount = 0
                while current != start, guardCount < 1_000_000 {
                    guardCount += 1
                    guard let options = next[current], !options.isEmpty else { break }
                    var pick = 0
                    if options.count > 1 {
                        let from = frame.local(positions[Int(previous)]), at = frame.local(positions[Int(current)])
                        let inDir = at - from
                        var bestAngle = -Double.infinity
                        for (i, o) in options.enumerated() {
                            let out = frame.local(positions[Int(o)]) - at
                            let angle = atan2(inDir.cross(out), inDir.dot(out))
                            if angle > bestAngle {
                                bestAngle = angle
                                pick = i
                            }
                        }
                    }
                    let chosen = options[pick]
                    next[current]!.remove(at: pick)
                    loop.append(current)
                    previous = current
                    current = chosen
                }
                if current == start, loop.count >= 3 { loops.append(loop) }
            }
        }
        return loops
    }

    private mutating func buildEdges() {
        struct Slot {
            var f0: Int32 = -1
            var f1: Int32 = -1
            var count = 0
        }
        var map: [SIMD2<Int32>: Slot] = [:]
        map.reserveCapacity(faces.count * 4)
        for (fi, f) in faces.enumerated() {
            for r in f.loops {
                for i in r {
                    let a = f.verts[i], b = f.verts[i + 1 == r.upperBound ? r.lowerBound : i + 1]
                    let key = SIMD2(min(a, b), max(a, b))
                    var slot = map[key] ?? Slot()
                    // f0 walks the edge low → high, so its loop direction is known.
                    if a < b, slot.f0 < 0 { slot.f0 = Int32(fi) } else if slot.f1 < 0 { slot.f1 = Int32(fi) }
                    slot.count += 1
                    map[key] = slot
                }
            }
        }
        edges = []
        edges.reserveCapacity(map.count)
        for key in map.keys.sorted(by: { ($0.x, $0.y) < ($1.x, $1.y) }) {
            let s = map[key]!
            var f0 = s.f0, f1 = s.f1
            if f0 < 0 { swap(&f0, &f1) }
            guard s.count == 2, f0 >= 0, f1 >= 0 else {
                edges.append(SolidEdge(a: key.x, b: key.y, f0: max(f0, f1), f1: -1, kind: .open))
                continue
            }
            let n0 = faces[Int(f0)].plane.normal, n1 = faces[Int(f1)].plane.normal
            let c = simd_dot(n0, n1)
            let kind: EdgeKind
            if faces[Int(f0)].tag == faces[Int(f1)].tag {
                kind = c > cos(50 * .pi / 180) ? .smooth : .sharp
            } else if c > 1 - 1e-7 {
                kind = .seamless
            } else if c > cos(3 * .pi / 180) {
                kind = .tangent
            } else {
                kind = .sharp
            }
            edges.append(SolidEdge(a: key.x, b: key.y, f0: f0, f1: f1, kind: kind))
        }
    }

    /// The solid's triangles as polygons (the form booleans work on).
    public func polygons() -> [Polygon3] {
        var out: [Polygon3] = []
        out.reserveCapacity(triangleCount)
        for f in faces {
            var i = 0
            while i + 2 < f.triangles.count {
                let a = Int(f.triangles[i]), b = Int(f.triangles[i + 1]), c = Int(f.triangles[i + 2])
                out.append(Polygon3(verts: [MeshVertex(positions[Int(f.verts[a])], f.normals[a]),
                                            MeshVertex(positions[Int(f.verts[b])], f.normals[b]),
                                            MeshVertex(positions[Int(f.verts[c])], f.normals[c])],
                                    plane: f.plane, tag: f.tag))
                i += 3
            }
        }
        return out
    }

    /// Splits off disconnected pieces. A piece with negative volume is a cavity and stays with whatever surrounds it.
    public func separated() -> [Solid] {
        guard !faces.isEmpty else { return [] }
        var parent = Array(0..<faces.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }
        for e in edges where e.f1 >= 0 {
            let a = find(Int(e.f0)), b = find(Int(e.f1))
            if a != b { parent[a] = b }
        }
        var groups: [Int: [Int]] = [:]
        for i in faces.indices { groups[find(i), default: []].append(i) }
        if groups.count == 1 { return [self] }

        struct Piece {
            var polys: [Polygon3]
            var solid: Solid
            var volume: Double
        }
        let pieces: [Piece] = groups.keys.sorted().map { key in
            var polys: [Polygon3] = []
            for fi in groups[key]! {
                let f = faces[fi]
                var i = 0
                while i + 2 < f.triangles.count {
                    let a = Int(f.triangles[i]), b = Int(f.triangles[i + 1]), c = Int(f.triangles[i + 2])
                    polys.append(Polygon3(verts: [MeshVertex(positions[Int(f.verts[a])], f.normals[a]),
                                                  MeshVertex(positions[Int(f.verts[b])], f.normals[b]),
                                                  MeshVertex(positions[Int(f.verts[c])], f.normals[c])],
                                          plane: f.plane, tag: f.tag))
                    i += 3
                }
            }
            let s = Solid(polygons: polys)
            return Piece(polys: polys, solid: s, volume: s.massProperties().volume)
        }
        var shells = pieces.filter { $0.volume > 0 }
        for cavity in pieces where cavity.volume <= 0 {
            guard let probe = cavity.solid.positions.first else { continue }
            let owners = shells.indices.filter { shells[$0].solid.bounds.overlaps(cavity.solid.bounds) && shells[$0].solid.contains(probe) }
            if let owner = owners.min(by: { shells[$0].volume < shells[$1].volume }) {
                shells[owner].polys += cavity.polys
                shells[owner].solid = Solid(polygons: shells[owner].polys)
            }
        }
        return shells.map(\.solid)
    }

    /// Is the point inside? Casts a slightly skewed ray and counts how many times it crosses the skin.
    public func contains(_ p: Vec3) -> Bool {
        guard bounds.overlaps(AABB(lo: p, hi: p), tolerance: 1e-9) else { return false }
        let dir = simd_normalize(Vec3(0.5773, 0.4142, 0.7071))
        var crossings = 0
        for f in faces {
            var i = 0
            while i + 2 < f.triangles.count {
                let a = positions[Int(f.verts[Int(f.triangles[i])])]
                let b = positions[Int(f.verts[Int(f.triangles[i + 1])])]
                let c = positions[Int(f.verts[Int(f.triangles[i + 2])])]
                i += 3
                if let t = rayTriangle(origin: p, dir: dir, a, b, c), t > 1e-12 { crossings += 1 }
            }
        }
        return crossings % 2 == 1
    }

    /// Shortest distance from a point to the part of the skin carrying `tag`.
    func distance(from p: Vec3, toFacesTagged tag: FaceTag) -> Double {
        var best = Double.infinity
        for f in faces where f.tag == tag {
            var i = 0
            while i + 2 < f.triangles.count {
                let a = positions[Int(f.verts[Int(f.triangles[i])])]
                let b = positions[Int(f.verts[Int(f.triangles[i + 1])])]
                let c = positions[Int(f.verts[Int(f.triangles[i + 2])])]
                i += 3
                best = min(best, simd_length(closestPointOnTriangle(p, a, b, c) - p))
            }
        }
        return best
    }

    public func faces(tagged tag: FaceTag) -> [SolidFace] { faces.filter { $0.tag == tag } }
}

/// Merges positions within the weld tolerance using a hash grid.
struct VertexWelder {
    var positions: [Vec3] = []
    private var grid: [SIMD3<Int64>: [Int32]] = [:]
    private let cell = Solid.weldTolerance * 4

    mutating func id(for p: Vec3) -> Int32 {
        let c = SIMD3<Int64>(Int64((p.x / cell).rounded(.down)), Int64((p.y / cell).rounded(.down)), Int64((p.z / cell).rounded(.down)))
        let tol2 = Solid.weldTolerance * Solid.weldTolerance
        for dx in -1...1 {
            for dy in -1...1 {
                for dz in -1...1 {
                    if let list = grid[c &+ SIMD3(Int64(dx), Int64(dy), Int64(dz))] {
                        for i in list where simd_length_squared(positions[Int(i)] - p) <= tol2 { return i }
                    }
                }
            }
        }
        let id = Int32(positions.count)
        positions.append(p)
        grid[c, default: []].append(id)
        return id
    }
}

/// Finds points near a segment without testing every point.
struct SpatialGrid {
    let cell: Double
    var items: [SIMD3<Int64>: [(Int32, Vec3)]] = [:]

    init(cell: Double) { self.cell = cell }

    private func key(_ p: Vec3) -> SIMD3<Int64> {
        SIMD3<Int64>(Int64((p.x / cell).rounded(.down)), Int64((p.y / cell).rounded(.down)), Int64((p.z / cell).rounded(.down)))
    }

    mutating func insert(_ id: Int32, at p: Vec3) { items[key(p), default: []].append((id, p)) }

    func visit(from a: Vec3, to b: Vec3, _ body: (Int32) -> Void) {
        let lo = key(simd_min(a, b)), hi = key(simd_max(a, b))
        let extent = hi &- lo
        let cells = (extent.x + 1) * (extent.y + 1) * (extent.z + 1)
        if cells > Int64(items.count) {
            // A long diagonal edge spans more cells than exist: just check the stored ones.
            for list in items.values { for (id, _) in list { body(id) } }
            return
        }
        for x in (lo.x - 1)...(hi.x + 1) {
            for y in (lo.y - 1)...(hi.y + 1) {
                for z in (lo.z - 1)...(hi.z + 1) {
                    if let list = items[SIMD3(x, y, z)] { for (id, _) in list { body(id) } }
                }
            }
        }
    }
}

/// Möller–Trumbore ray/triangle intersection: distance along the ray, or nil when it misses.
public func rayTriangle(origin: Vec3, dir: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Double? {
    let e1 = b - a, e2 = c - a
    let p = simd_cross(dir, e2)
    let det = simd_dot(e1, p)
    if abs(det) < 1e-14 { return nil }
    let inv = 1 / det
    let s = origin - a
    let u = simd_dot(s, p) * inv
    if u < 0 || u > 1 { return nil }
    let q = simd_cross(s, e1)
    let v = simd_dot(dir, q) * inv
    if v < 0 || u + v > 1 { return nil }
    return simd_dot(e2, q) * inv
}

public func closestPointOnTriangle(_ p: Vec3, _ a: Vec3, _ b: Vec3, _ c: Vec3) -> Vec3 {
    let ab = b - a, ac = c - a, ap = p - a
    let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
    if d1 <= 0, d2 <= 0 { return a }
    let bp = p - b
    let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
    if d3 >= 0, d4 <= d3 { return b }
    let vc = d1 * d4 - d3 * d2
    if vc <= 0, d1 >= 0, d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
    let cp = p - c
    let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
    if d6 >= 0, d5 <= d6 { return c }
    let vb = d5 * d2 - d1 * d6
    if vb <= 0, d2 >= 0, d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
    let va = d3 * d6 - d5 * d4
    if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
    let denom = 1 / (va + vb + vc)
    return a + ab * (vb * denom) + ac * (vc * denom)
}
