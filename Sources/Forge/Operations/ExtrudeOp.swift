import Foundation
import simd

public struct FeatureError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Pushes a region along its plane's normal, keeping or tapering its outline.
public enum ExtrudeOp {
    /// One outline at a given height. `offset` shrinks the outline inward: that's how draft is built.
    public struct Ring: Equatable {
        public var height: Double
        public var offset: Double

        public init(height: Double, offset: Double = 0) {
            self.height = height
            self.offset = offset
        }
    }

    /// Moves every point of a loop inward by `offset`, keeping each edge parallel to where it was.
    static func offsetLoop(_ loop: ProfileLoop, by offset: Double) -> [Vec2] {
        let pts = loop.points
        guard offset != 0 else { return pts }
        let n = pts.count
        var out = [Vec2](repeating: .zero, count: n)
        for i in 0..<n {
            let prev = simd_normalize(pts[i] - pts[(i + n - 1) % n])
            let next = simd_normalize(pts[(i + 1) % n] - pts[i])
            // "Left" of a counter-clockwise walk is inward, and for a clockwise hole it is into the material.
            let leftA = Vec2(-prev.y, prev.x), leftB = Vec2(-next.y, next.x)
            let mitre = leftA + leftB
            let m = simd_length(mitre)
            guard m > 1e-9 else {
                out[i] = pts[i] + leftA * offset
                continue
            }
            let dir = mitre / m
            out[i] = pts[i] + dir * (offset / max(simd_dot(dir, leftA), 0.2))
        }
        return out
    }

    /// The closed polygons of an extrusion between the given rings (lowest height first).
    public static func polygons(region: ProfileRegion, frame: Frame3, rings: [Ring], feature: Int) throws -> [Polygon3] {
        guard rings.count >= 2 else { throw FeatureError("An extrusion needs two heights") }
        var polys: [Polygon3] = []

        func wall(_ loop: ProfileLoop) throws {
            let outlines = rings.map { offsetLoop(loop, by: $0.offset) }
            for r in outlines.indices where signedArea(outlines[r]) * loop.area <= 0 {
                throw FeatureError("The draft angle closes the profile before reaching the end")
            }
            let n = loop.edges.count
            for r in 0..<(rings.count - 1) {
                let lowH = rings[r].height, highH = rings[r + 1].height
                let dh = highH - lowH, shrink = rings[r + 1].offset - rings[r].offset
                // Slope of the wall: how far the surface normal tips towards the axis because of draft.
                let tilt = abs(dh) > 1e-12 ? shrink / dh : 0
                for i in 0..<n {
                    let j = (i + 1) % n
                    let e = loop.edges[i]
                    let tag = FaceTag(feature: feature, role: .side, entity: e.curve)
                    let a0 = frame.world(outlines[r][i], height: lowH), b0 = frame.world(outlines[r][j], height: lowH)
                    let b1 = frame.world(outlines[r + 1][j], height: highH), a1 = frame.world(outlines[r + 1][i], height: highH)
                    if let s = e.smoothNormals {
                        // Arcs: radial shading normals, flipped when the loop runs the other way round the centre.
                        let outward = (e.b - e.a).rightNormal
                        let flip = simd_dot(outward, s.a + s.b) >= 0 ? 1.0 : -1.0
                        func shade(_ m: Vec2) -> Vec3 {
                            simd_normalize(frame.x * (m.x * flip) + frame.y * (m.y * flip) + frame.z * tilt)
                        }
                        if let p = Polygon3(smooth: [MeshVertex(a0, shade(s.a)), MeshVertex(b0, shade(s.b)),
                                                     MeshVertex(b1, shade(s.b)), MeshVertex(a1, shade(s.a))], tag: tag) {
                            polys.append(p)
                        }
                    } else if let p = Polygon3(flat: [a0, b0, b1, a1], tag: tag) {
                        polys.append(p)
                    }
                }
            }
        }

        try wall(region.outer)
        for h in region.holes { try wall(h) }

        // Flat ends. Triangulating the offset outlines keeps them consistent with the walls.
        func cap(_ ring: Ring, role: FaceTag.Role, faceUp: Bool) {
            let outer = offsetLoop(region.outer, by: ring.offset)
            let holes = region.holes.map { offsetLoop($0, by: ring.offset) }
            let tris = Triangulator.triangulate(outer: outer, holes: holes)
            let all = outer + holes.flatMap { $0 }
            let tag = FaceTag(feature: feature, role: role)
            var i = 0
            while i + 2 < tris.count {
                let a = frame.world(all[Int(tris[i])], height: ring.height)
                let b = frame.world(all[Int(tris[i + 1])], height: ring.height)
                let c = frame.world(all[Int(tris[i + 2])], height: ring.height)
                if let p = Polygon3(flat: faceUp ? [a, b, c] : [c, b, a], tag: tag) { polys.append(p) }
                i += 3
            }
        }
        cap(rings[0], role: .startCap, faceUp: false)
        cap(rings[rings.count - 1], role: .endCap, faceUp: true)
        return polys
    }

    /// One solid from several regions. Touching regions fuse; separate ones stay in the same polygon soup
    /// and split into bodies later.
    public static func solid(regions: [ProfileRegion], frame: Frame3, rings: [Ring], feature: Int) throws -> Solid {
        // Regions that can't touch skip the booleans altogether: one polygon soup is much faster for many holes.
        let boxes = regions.map { r -> (lo: Vec2, hi: Vec2) in
            let pts = r.outer.points
            return (pts.reduce(pts[0]) { simd_min($0, $1) }, pts.reduce(pts[0]) { simd_max($0, $1) })
        }
        var separate = true
        outer: for i in boxes.indices {
            for j in boxes.indices where j > i {
                let a = boxes[i], b = boxes[j]
                if a.lo.x <= b.hi.x, b.lo.x <= a.hi.x, a.lo.y <= b.hi.y, b.lo.y <= a.hi.y {
                    separate = false
                    break outer
                }
            }
        }
        if separate {
            var all: [Polygon3] = []
            for region in regions { all += try polygons(region: region, frame: frame, rings: rings, feature: feature) }
            return Solid(polygons: all)
        }
        var result = Solid()
        for region in regions {
            let piece = Solid(polygons: try polygons(region: region, frame: frame, rings: rings, feature: feature))
            result = result.isEmpty ? piece : CSG.combine(result, piece, .union)
        }
        return result
    }
}

/// Spins a region around an axis in its own plane.
public enum RevolveOp {
    /// `axisA`, `axisB`: two points on the axis in sketch coordinates. `angle` in radians; 2π makes a closed solid.
    public static func solid(regions: [ProfileRegion], frame: Frame3, axisA: Vec2, axisB: Vec2, angle: Double, feature: Int) throws -> Solid {
        let axisDir2 = axisB - axisA
        guard simd_length(axisDir2) > 1e-9 else { throw FeatureError("The revolve axis has no length") }
        let unit2 = simd_normalize(axisDir2)
        guard abs(angle) > 1e-6 else { throw FeatureError("The revolve angle is zero") }
        let sweep = min(abs(angle), 2 * .pi)
        let isFull = sweep > 2 * .pi - 1e-9
        let direction = angle < 0 ? -1.0 : 1.0

        var result = Solid()
        for region in regions {
            // Everything must stay on one side of the axis, or the solid would pass through itself.
            let offs = region.allPoints.map { unit2.cross($0 - axisA) }
            guard let lo = offs.min(), let hi = offs.max() else { continue }
            guard lo > -1e-7 || hi < 1e-7 else { throw FeatureError("The profile crosses the revolve axis") }
            let maxR = max(abs(lo), abs(hi))
            let steps = max(3, Int((Double(circleSegments(radius: maxR)) * sweep / (2 * .pi)).rounded(.up)))

            let axisOrigin = frame.world(axisA)
            let axis = simd_normalize(frame.x * unit2.x + frame.y * unit2.y)
            func rotate(_ v: Vec3, _ t: Double) -> Vec3 {
                let a = t * direction
                return v * cos(a) + simd_cross(axis, v) * sin(a) + axis * simd_dot(axis, v) * (1 - cos(a))
            }
            func place(_ p: Vec2, _ t: Double) -> Vec3 { axisOrigin + rotate(frame.world(p) - axisOrigin, t) }

            var polys: [Polygon3] = []
            func wall(_ loop: ProfileLoop) {
                for e in loop.edges {
                    let tag = FaceTag(feature: feature, role: .side, entity: e.curve)
                    var outward = (e.b - e.a).rightNormal
                    outward = simd_length(outward) > 0 ? simd_normalize(outward) : outward
                    var na = outward, nb = outward
                    if let s = e.smoothNormals {
                        let flip = simd_dot(outward, s.a + s.b) >= 0 ? 1.0 : -1.0
                        na = s.a * flip
                        nb = s.b * flip
                    }
                    let world = { (m: Vec2) in frame.x * m.x + frame.y * m.y }
                    for k in 0..<steps {
                        let t0 = sweep * Double(k) / Double(steps), t1 = sweep * Double(k + 1) / Double(steps)
                        let v = [MeshVertex(place(e.a, t0), rotate(world(na), t0)), MeshVertex(place(e.b, t0), rotate(world(nb), t0)),
                                 MeshVertex(place(e.b, t1), rotate(world(nb), t1)), MeshVertex(place(e.a, t1), rotate(world(na), t1))]
                        // Corners on the axis collapse, turning quads into triangles.
                        var clean: [MeshVertex] = []
                        for m in v where !clean.contains(where: { simd_length($0.p - m.p) < 1e-9 }) { clean.append(m) }
                        if clean.count >= 3, let p = Polygon3(smooth: clean, tag: tag) { polys.append(p) }
                    }
                }
            }
            wall(region.outer)
            region.holes.forEach(wall)

            if !isFull {
                let pts = region.allPoints, tris = region.triangles()
                var i = 0
                while i + 2 < tris.count {
                    let a = pts[Int(tris[i])], b = pts[Int(tris[i + 1])], c = pts[Int(tris[i + 2])]
                    if let p = Polygon3(flat: [place(c, 0), place(b, 0), place(a, 0)], tag: FaceTag(feature: feature, role: .startCap)) { polys.append(p) }
                    if let p = Polygon3(flat: [place(a, sweep), place(b, sweep), place(c, sweep)], tag: FaceTag(feature: feature, role: .endCap)) { polys.append(p) }
                    i += 3
                }
            }
            // Which way round the surface ends up depends on the axis direction: check the volume and flip if inside out.
            let attempt = Solid(polygons: polys)
            let piece = attempt.massProperties().volume < 0 ? Solid(polygons: polys.map(\.flippedKeepingNormals)) : attempt
            result = result.isEmpty ? piece : CSG.combine(result, piece, .union)
        }
        return result
    }
}

extension Polygon3 {
    /// Reverses the winding but keeps shading normals in their true outward direction, unless they
    /// turned out wrong as well: `outward` chooses.
    var flippedKeepingNormals: Polygon3 {
        // Winding and normals were both built from the same wrong assumption about which way the walk ran.
        Polygon3(verts: verts.reversed().map { MeshVertex($0.p, simd_dot($0.n, plane.normal) > 0 ? -$0.n : $0.n) },
                 plane: plane.flipped, tag: tag)
    }
}

/// Lofts between profiles, or sweeps one along a path.
public enum LoftSweepOp {
    /// Distance along a closed loop, as a fraction of its length, at each corner.
    private static func parameters(_ loop: [Vec3]) -> [Double] {
        var lengths = [0.0]
        for i in loop.indices { lengths.append(lengths.last! + simd_length(loop[(i + 1) % loop.count] - loop[i])) }
        let total = max(lengths.last!, 1e-12)
        return lengths.dropLast().map { $0 / total }
    }

    /// Points on a closed loop at the given fractions of its length.
    static func sample(_ loop: [Vec3], at params: [Double]) -> [Vec3] {
        var lengths = [0.0]
        for i in loop.indices { lengths.append(lengths.last! + simd_length(loop[(i + 1) % loop.count] - loop[i])) }
        let total = lengths.last!
        var seg = 0
        return params.map { u in
            let s = total * u
            while seg + 1 < lengths.count - 1, lengths[seg + 1] <= s { seg += 1 }
            let t = (s - lengths[seg]) / max(lengths[seg + 1] - lengths[seg], 1e-12)
            return loop[seg] + (loop[(seg + 1) % loop.count] - loop[seg]) * t
        }
    }

    /// Closed solid through rings of equal size. Each ring is walked in the same rotational sense.
    static func skin(rings: [[Vec3]], feature: Int) throws -> Solid {
        guard rings.count >= 2, let n = rings.first?.count, n >= 3 else { throw FeatureError("A loft needs at least two profiles") }
        var polys: [Polygon3] = []
        let tag = FaceTag(feature: feature, role: .loftSide)
        // The surface's direction at each point, from its neighbours in both directions, shades it as one smooth skin.
        func normal(_ r: Int, _ i: Int) -> Vec3 {
            let along = rings[r][(i + 1) % n] - rings[r][(i + n - 1) % n]
            let up = rings[min(r + 1, rings.count - 1)][i] - rings[max(r - 1, 0)][i]
            let c = simd_cross(along, up)
            return simd_length_squared(c) > 0 ? simd_normalize(c) : c
        }
        for r in 0..<(rings.count - 1) {
            for i in 0..<n {
                let j = (i + 1) % n
                let a = MeshVertex(rings[r][i], normal(r, i)), b = MeshVertex(rings[r][j], normal(r, j))
                let c = MeshVertex(rings[r + 1][j], normal(r + 1, j)), d = MeshVertex(rings[r + 1][i], normal(r + 1, i))
                // Ruled quads aren't generally flat: two triangles.
                if let p = Polygon3(smooth: [a, b, c], tag: tag) { polys.append(p) }
                if let p = Polygon3(smooth: [a, c, d], tag: tag) { polys.append(p) }
            }
        }
        // Newell's normal follows the ring's walking direction, so the triangles below wind the same way as the
        // ring. The far end faces along the walk, the near end against it.
        func fan(_ ring: [Vec3], role: FaceTag.Role, reversed: Bool) {
            guard let plane = Plane3.fit(ring) else { return }
            let frame = Frame3.on(plane: plane, near: ring[0])
            let tris = Triangulator.triangulate(outer: ring.map { frame.local($0) })
            var i = 0
            while i + 2 < tris.count {
                let tri = [ring[Int(tris[i])], ring[Int(tris[i + 1])], ring[Int(tris[i + 2])]]
                if let p = Polygon3(flat: reversed ? tri.reversed() : tri, tag: FaceTag(feature: feature, role: role)) {
                    polys.append(p)
                }
                i += 3
            }
        }
        fan(rings[0], role: .startCap, reversed: true)
        fan(rings[rings.count - 1], role: .endCap, reversed: false)
        let attempt = Solid(polygons: polys)
        return attempt.massProperties().volume < 0 ? Solid(polygons: polys.map(\.flipped)) : attempt
    }

    /// Ruled loft through outlines in order. Each outline is first turned to line up with the previous one, then
    /// all are sampled at the same places, including every corner of every outline so that none gets clipped.
    public static func loft(loops: [[Vec3]], feature: Int) throws -> Solid {
        guard loops.count >= 2 else { throw FeatureError("Pick at least two profiles to loft between") }
        var aligned = loops
        let coarse = (0..<96).map { Double($0) / 96 }
        for r in 1..<aligned.count {
            let prev = sample(aligned[r - 1], at: coarse)
            let prevCenter = prev.reduce(Vec3.zero, +) / 96
            var best = (cost: Double.infinity, start: Vec3.zero, reversed: false)
            for reversed in [false, true] {
                let candidate = sample(reversed ? Array(aligned[r].reversed()) : aligned[r], at: coarse)
                let center = candidate.reduce(Vec3.zero, +) / 96
                for shift in 0..<96 {
                    var cost = 0.0
                    for i in stride(from: 0, to: 96, by: 4) {
                        cost += simd_length_squared((prev[i] - prevCenter) - (candidate[(i + shift) % 96] - center))
                    }
                    if cost < best.cost { best = (cost, candidate[shift], reversed) }
                }
            }
            var loop = best.reversed ? Array(aligned[r].reversed()) : aligned[r]
            // Start from the corner closest to where the best alignment begins.
            if let first = loop.indices.min(by: { simd_length_squared(loop[$0] - best.start) < simd_length_squared(loop[$1] - best.start) }) {
                loop = Array(loop[first...] + loop[..<first])
            }
            aligned[r] = loop
        }
        var params = aligned.flatMap(parameters).sorted()
        var unique: [Double] = []
        for u in params where unique.last.map({ u - $0 > 1e-6 }) ?? true { unique.append(u) }
        // A loft between two simple outlines still needs enough steps to look round where one of them is.
        if unique.count < 8 {
            params = (0..<48).map { Double($0) / 48 }
            unique = Array(Set(unique + params)).sorted()
        }
        return try skin(rings: aligned.map { sample($0, at: unique) }, feature: feature)
    }

    /// Moves a region's outline along a path without twisting it (rotation-minimising frames).
    public static func sweep(outline: [Vec2], frame: Frame3, path: [Vec3], feature: Int) throws -> Solid {
        guard path.count >= 2 else { throw FeatureError("The sweep path needs at least two points") }
        guard outline.count >= 3 else { throw FeatureError("The sweep profile isn't closed") }
        var rings: [[Vec3]] = []
        var x = frame.x, y = frame.y
        var tangent = simd_normalize(path[1] - path[0])
        // The profile keeps its offset from where the path pierces its plane.
        let origin2 = frame.local(path[0])
        for i in path.indices {
            let t: Vec3
            if i == 0 {
                t = simd_normalize(path[1] - path[0])
            } else if i == path.count - 1 {
                t = simd_normalize(path[i] - path[i - 1])
            } else {
                t = simd_normalize(simd_normalize(path[i] - path[i - 1]) + simd_normalize(path[i + 1] - path[i]))
            }
            if i > 0 {
                // Rotate the frame by the smallest rotation taking the old tangent to the new one.
                let axis = simd_cross(tangent, t)
                let s = simd_length(axis)
                if s > 1e-12 {
                    let u = axis / s
                    let c = simd_dot(tangent, t)
                    func rot(_ v: Vec3) -> Vec3 { v * c + simd_cross(u, v) * s + u * simd_dot(u, v) * (1 - c) }
                    x = rot(x)
                    y = rot(y)
                }
            }
            tangent = t
            rings.append(outline.map { p in
                let d = p - origin2
                return path[i] + x * d.x + y * d.y
            })
        }
        return try skin(rings: rings, feature: feature)
    }
}
