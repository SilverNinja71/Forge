import Foundation
import simd

/// Boolean operations on solids, using binary space partitioning (BSP) trees.
///
/// A BSP tree slices space with the solid's face planes until every region is plainly inside or outside.
/// To clip a polygon against a solid, push it down the tree: it is split at each plane and the pieces landing
/// in "inside" regions are thrown away. Union, cut and intersect are all the same step with some solids
/// turned inside out (A − B = not(not A ∪ B)).
public enum CSG {
    public enum Operation: String, Codable, Sendable {
        case union, subtract, intersect
    }

    /// Anything closer to a plane than this counts as on it: a tenth of a nanometre.
    static let planeEpsilon = 1e-7

    final class Tree {
        struct Node {
            var plane: Plane3
            var front: Int32 = -1
            var back: Int32 = -1
        }

        var nodes: [Node] = []

        /// Builds the tree from a solid's distinct planes. All the triangles of a flat face share one plane, so
        /// the tree stays far smaller than the triangle count.
        init(solid: Solid) {
            struct PlaneWork {
                var plane: Plane3
                var pieces: [[Vec3]]
            }
            // Represent each face by its triangles; only their positions matter for routing.
            var work: [PlaneWork] = []
            work.reserveCapacity(solid.faces.count)
            var byTagPlane: [SIMD4<Int64>: Int] = [:]
            for f in solid.faces {
                var tris: [[Vec3]] = []
                var i = 0
                while i + 2 < f.triangles.count {
                    tris.append([solid.positions[Int(f.verts[Int(f.triangles[i])])],
                                 solid.positions[Int(f.verts[Int(f.triangles[i + 1])])],
                                 solid.positions[Int(f.verts[Int(f.triangles[i + 2])])]])
                    i += 3
                }
                let key = SIMD4<Int64>(Int64((f.plane.normal.x * 1e7).rounded()), Int64((f.plane.normal.y * 1e7).rounded()),
                                       Int64((f.plane.normal.z * 1e7).rounded()), Int64((f.plane.d * 1e5).rounded()))
                if let at = byTagPlane[key] {
                    work[at].pieces += tris
                } else {
                    byTagPlane[key] = work.count
                    work.append(PlaneWork(plane: f.plane, pieces: tris))
                }
            }
            guard !work.isEmpty else { return }

            // Explicit stack: a convex solid makes a deep, list-shaped tree and recursion could overflow.
            struct Task {
                var items: [PlaneWork]
                var parent: Int32
                var isFront: Bool
            }
            var stack = [Task(items: work, parent: -1, isFront: true)]
            while let task = stack.popLast() {
                var items = task.items
                guard !items.isEmpty else { continue }
                // Choose, from a small sample, the plane that cuts the fewest other pieces.
                var bestIndex = 0
                if items.count > 1 {
                    var bestScore = Int.max
                    let step = max(1, items.count / 8)
                    for candidate in stride(from: 0, to: items.count, by: step) {
                        let plane = items[candidate].plane
                        var splits = 0, front = 0, back = 0
                        for (k, other) in items.enumerated() where k != candidate {
                            for piece in other.pieces {
                                var hasF = false, hasB = false
                                for p in piece {
                                    let d = plane.distance(p)
                                    if d > CSG.planeEpsilon { hasF = true } else if d < -CSG.planeEpsilon { hasB = true }
                                }
                                if hasF && hasB { splits += 1 } else if hasF { front += 1 } else if hasB { back += 1 }
                            }
                        }
                        let score = splits * 8 + abs(front - back)
                        if score < bestScore {
                            bestScore = score
                            bestIndex = candidate
                        }
                    }
                }
                let split = items.remove(at: bestIndex).plane
                let index = Int32(nodes.count)
                nodes.append(Node(plane: split))
                if task.parent >= 0 {
                    if task.isFront { nodes[Int(task.parent)].front = index } else { nodes[Int(task.parent)].back = index }
                }
                var fronts: [PlaneWork] = [], backs: [PlaneWork] = []
                for item in items {
                    var fp: [[Vec3]] = [], bp: [[Vec3]] = []
                    for piece in item.pieces {
                        CSG.split(piece, by: split, front: &fp, back: &bp)
                    }
                    if !fp.isEmpty { fronts.append(PlaneWork(plane: item.plane, pieces: fp)) }
                    if !bp.isEmpty { backs.append(PlaneWork(plane: item.plane, pieces: bp)) }
                }
                stack.append(Task(items: fronts, parent: index, isFront: true))
                stack.append(Task(items: backs, parent: index, isFront: false))
            }
        }

        /// Keeps the parts of polygons outside the solid. With `inverted`, the tree acts as the solid turned inside out.
        func clip(_ polys: [Polygon3], inverted: Bool, into output: inout [Polygon3]) {
            guard !nodes.isEmpty else {
                // A tree with no planes is empty space (or, inverted, solid everywhere).
                if !inverted { output += polys }
                return
            }
            var stack: [(Int32, Polygon3)] = []
            stack.reserveCapacity(64)
            for p in polys {
                stack.append((0, p))
                while let (ni, poly) = stack.popLast() {
                    let node = nodes[Int(ni)]
                    let plane = inverted ? node.plane.flipped : node.plane
                    let frontChild = inverted ? node.back : node.front
                    let backChild = inverted ? node.front : node.back
                    let (f, b) = CSG.split(poly, by: plane)
                    if let f {
                        if frontChild < 0 { output.append(f) } else { stack.append((frontChild, f)) }
                    }
                    if let b, backChild >= 0 { stack.append((backChild, b)) }
                }
            }
        }
    }

    /// Splits a triangle-ish piece for tree building. Coplanar pieces drop out: their plane is already in the tree.
    fileprivate static func split(_ piece: [Vec3], by plane: Plane3, front: inout [[Vec3]], back: inout [[Vec3]]) {
        var hasF = false, hasB = false
        var dist = [Double](repeating: 0, count: piece.count)
        for i in piece.indices {
            let d = plane.distance(piece[i])
            dist[i] = d
            if d > planeEpsilon { hasF = true } else if d < -planeEpsilon { hasB = true }
        }
        if !hasF && !hasB { return }
        if hasF && !hasB {
            front.append(piece)
            return
        }
        if hasB && !hasF {
            back.append(piece)
            return
        }
        var f: [Vec3] = [], b: [Vec3] = []
        for i in piece.indices {
            let j = (i + 1) % piece.count
            let di = dist[i], dj = dist[j]
            if di >= -planeEpsilon { f.append(piece[i]) }
            if di <= planeEpsilon { b.append(piece[i]) }
            if (di > planeEpsilon && dj < -planeEpsilon) || (di < -planeEpsilon && dj > planeEpsilon) {
                let hit = piece[i] + (piece[j] - piece[i]) * (di / (di - dj))
                f.append(hit)
                b.append(hit)
            }
        }
        if f.count >= 3 { front.append(f) }
        if b.count >= 3 { back.append(b) }
    }

    /// Splits a polygon by a plane. A polygon lying in the plane goes to the side its normal faces.
    static func split(_ poly: Polygon3, by plane: Plane3) -> (front: Polygon3?, back: Polygon3?) {
        var hasF = false, hasB = false
        let verts = poly.verts
        for v in verts {
            let d = plane.distance(v.p)
            if d > planeEpsilon { hasF = true } else if d < -planeEpsilon { hasB = true }
        }
        if !hasF && !hasB {
            return simd_dot(plane.normal, poly.plane.normal) > 0 ? (poly, nil) : (nil, poly)
        }
        if hasF && !hasB { return (poly, nil) }
        if hasB && !hasF { return (nil, poly) }
        var f: [MeshVertex] = [], b: [MeshVertex] = []
        f.reserveCapacity(verts.count + 1)
        b.reserveCapacity(verts.count + 1)
        for i in verts.indices {
            let j = i + 1 == verts.count ? 0 : i + 1
            let vi = verts[i], vj = verts[j]
            let di = plane.distance(vi.p), dj = plane.distance(vj.p)
            if di >= -planeEpsilon { f.append(vi) }
            if di <= planeEpsilon { b.append(vi) }
            if (di > planeEpsilon && dj < -planeEpsilon) || (di < -planeEpsilon && dj > planeEpsilon) {
                let t = di / (di - dj)
                let n = vi.n + (vj.n - vi.n) * t
                let hit = MeshVertex(vi.p + (vj.p - vi.p) * t, simd_length_squared(n) > 0 ? simd_normalize(n) : vi.n)
                f.append(hit)
                b.append(hit)
            }
        }
        return (f.count >= 3 ? Polygon3(verts: f, plane: poly.plane, tag: poly.tag) : nil,
                b.count >= 3 ? Polygon3(verts: b, plane: poly.plane, tag: poly.tag) : nil)
    }

    /// Union, subtraction (a − b) or intersection of two solids.
    public static func combine(_ a: Solid, _ b: Solid, _ op: Operation) -> Solid {
        if a.isEmpty { return op == .union ? b : Solid() }
        if b.isEmpty { return op == .intersect ? Solid() : a }

        let disjoint = !a.bounds.overlaps(b.bounds, tolerance: planeEpsilon * 10)
        if disjoint {
            switch op {
            case .union: return Solid(polygons: a.polygons() + b.polygons())
            case .subtract: return a
            case .intersect: return Solid()
            }
        }

        // Every operation is a union with some inputs inverted (De Morgan).
        let invertA = op != .union
        let invertB = op == .intersect
        let treeA = Tree(solid: a), treeB = Tree(solid: b)
        let polysA = a.polygons(), polysB = b.polygons()
        let overlap = planeEpsilon * 10

        func boxOf(_ p: Polygon3) -> AABB { AABB(points: p.verts.map(\.p)) }

        // P' = pieces of P outside Q. Pieces beyond Q's bounding box skip the tree: their answer is known.
        var resultP: [Polygon3] = []
        var pNear: [Polygon3] = []
        for p in polysA {
            let poly = invertA ? p.flipped : p
            if boxOf(p).overlaps(b.bounds, tolerance: overlap) {
                pNear.append(poly)
            } else if !invertB {
                resultP.append(poly)
            }
        }
        treeB.clip(pNear, inverted: invertB, into: &resultP)

        // Q' = pieces of Q outside P, minus any that exactly duplicate a kept face of P.
        var resultQ: [Polygon3] = []
        var qNear: [Polygon3] = []
        for p in polysB {
            let poly = invertB ? p.flipped : p
            if boxOf(p).overlaps(a.bounds, tolerance: overlap) {
                qNear.append(poly)
            } else if !invertA {
                resultQ.append(poly)
            }
        }
        var clipped: [Polygon3] = []
        treeA.clip(qNear, inverted: invertA, into: &clipped)
        var once: [Polygon3] = []
        treeA.clip(clipped.map(\.flipped), inverted: invertA, into: &once)
        resultQ += once.map(\.flipped)

        let merged = resultP + resultQ
        let finalPolys = invertA ? merged.map(\.flipped) : merged
        return Solid(polygons: finalPolys)
    }
}
