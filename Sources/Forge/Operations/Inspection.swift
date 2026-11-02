import Foundation
import simd

/// Volume, surface, balance point and resistance to rotation, integrated exactly over the triangles.
public struct MassProperties: Equatable, Sendable {
    /// mm³
    public var volume = 0.0
    /// mm²
    public var surfaceArea = 0.0
    public var centerOfMass = Vec3.zero
    /// Moments of inertia about the centre of mass per unit density (mm⁵): Ixx, Iyy, Izz, Ixy, Iyz, Ixz.
    public var inertia = [Double](repeating: 0, count: 6)
}

extension Solid {
    /// Uses the divergence theorem: each triangle plus the origin forms a signed tetrahedron, and summing
    /// those tetrahedra gives the integrals over the whole enclosed volume.
    public func massProperties() -> MassProperties {
        var volume = 0.0, area = 0.0
        var first = Vec3.zero
        var xx = 0.0, yy = 0.0, zz = 0.0, xy = 0.0, yz = 0.0, xz = 0.0
        for f in faces {
            var i = 0
            while i + 2 < f.triangles.count {
                let a = positions[Int(f.verts[Int(f.triangles[i])])]
                let b = positions[Int(f.verts[Int(f.triangles[i + 1])])]
                let c = positions[Int(f.verts[Int(f.triangles[i + 2])])]
                i += 3
                let cr = simd_cross(b - a, c - a)
                area += simd_length(cr) / 2
                let v = simd_dot(a, simd_cross(b, c)) / 6
                volume += v
                first += (a + b + c) * (v / 4)
                func second(_ p: Int, _ q: Int) -> Double {
                    (2 * (a[p] * a[q] + b[p] * b[q] + c[p] * c[q])
                        + a[p] * b[q] + a[q] * b[p] + a[p] * c[q] + a[q] * c[p] + b[p] * c[q] + b[q] * c[p]) * v / 20
                }
                xx += second(0, 0)
                yy += second(1, 1)
                zz += second(2, 2)
                xy += second(0, 1)
                yz += second(1, 2)
                xz += second(0, 2)
            }
        }
        var m = MassProperties()
        m.volume = volume
        m.surfaceArea = area
        guard abs(volume) > 1e-12 else { return m }
        let com = first / volume
        m.centerOfMass = com
        // Parallel-axis theorem moves the second moments from the origin to the centre of mass.
        let cxx = xx - volume * com.x * com.x, cyy = yy - volume * com.y * com.y, czz = zz - volume * com.z * com.z
        m.inertia = [cyy + czz, cxx + czz, cxx + cyy,
                     -(xy - volume * com.x * com.y), -(yz - volume * com.y * com.z), -(xz - volume * com.x * com.z)]
        return m
    }

    /// Smallest distance between two solids (0 if they touch or overlap), plus the two closest points.
    public func minimumDistance(to other: Solid) -> (distance: Double, a: Vec3, b: Vec3) {
        var best = Double.infinity
        var pa = Vec3.zero, pb = Vec3.zero
        func triangles(_ s: Solid) -> [(Vec3, Vec3, Vec3)] {
            var out: [(Vec3, Vec3, Vec3)] = []
            for f in s.faces {
                var i = 0
                while i + 2 < f.triangles.count {
                    out.append((s.positions[Int(f.verts[Int(f.triangles[i])])],
                                s.positions[Int(f.verts[Int(f.triangles[i + 1])])],
                                s.positions[Int(f.verts[Int(f.triangles[i + 2])])]))
                    i += 3
                }
            }
            return out
        }
        let ta = triangles(self), tb = triangles(other)
        // Closest pairs on triangle meshes occur at a vertex against a triangle or between two edges.
        func test(_ p: Vec3, _ tris: [(Vec3, Vec3, Vec3)], swapResult: Bool) {
            for t in tris {
                let q = closestPointOnTriangle(p, t.0, t.1, t.2)
                let d = simd_length(q - p)
                if d < best {
                    best = d
                    pa = swapResult ? q : p
                    pb = swapResult ? p : q
                }
            }
        }
        for p in positions { test(p, tb, swapResult: false) }
        for p in other.positions { test(p, ta, swapResult: true) }
        for e in edges {
            let a0 = positions[Int(e.a)], a1 = positions[Int(e.b)]
            for g in other.edges {
                let (p, q) = closestPoints(a0, a1, other.positions[Int(g.a)], other.positions[Int(g.b)])
                let d = simd_length(p - q)
                if d < best {
                    best = d
                    pa = p
                    pb = q
                }
            }
        }
        return (best, pa, pb)
    }
}

/// Closest points between two line segments.
func closestPoints(_ p1: Vec3, _ q1: Vec3, _ p2: Vec3, _ q2: Vec3) -> (Vec3, Vec3) {
    let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
    let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
    var s = 0.0, t = 0.0
    if a <= 1e-18, e <= 1e-18 { return (p1, p2) }
    if a <= 1e-18 {
        t = min(max(f / e, 0), 1)
    } else {
        let c = simd_dot(d1, r)
        if e <= 1e-18 {
            s = min(max(-c / a, 0), 1)
        } else {
            let b = simd_dot(d1, d2)
            let denom = a * e - b * b
            s = denom > 1e-18 ? min(max((b * f - c * e) / denom, 0), 1) : 0
            t = (b * s + f) / e
            if t < 0 {
                t = 0
                s = min(max(-c / a, 0), 1)
            } else if t > 1 {
                t = 1
                s = min(max((b - c) / a, 0), 1)
            }
        }
    }
    return (p1 + d1 * s, p2 + d2 * t)
}
