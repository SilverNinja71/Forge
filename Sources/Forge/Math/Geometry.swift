import Foundation
import simd

// All of Forge's modelling maths runs in double precision. Lengths are millimetres and angles radians
// everywhere inside the model; other units only exist at the edges (expressions, display).

public typealias Vec2 = SIMD2<Double>
public typealias Vec3 = SIMD3<Double>

/// An infinite plane: every point p on it satisfies `dot(normal, p) == d`.
public struct Plane3: Codable, Hashable, Sendable {
    public var normal: Vec3
    public var d: Double

    public init(normal: Vec3, d: Double) {
        self.normal = normal
        self.d = d
    }

    public init(normal: Vec3, through p: Vec3) {
        self.normal = normal
        self.d = simd_dot(normal, p)
    }

    /// Positive in front of the plane (the side the normal points to).
    @inline(__always) public func distance(_ p: Vec3) -> Double { simd_dot(normal, p) - d }
    public var flipped: Plane3 { Plane3(normal: -normal, d: -d) }

    /// Best-fit plane through a polygon (Newell's method, reliable even with collinear corners).
    public static func fit(_ loop: [Vec3]) -> Plane3? {
        var n = Vec3.zero
        var c = Vec3.zero
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            n.x += (a.y - b.y) * (a.z + b.z)
            n.y += (a.z - b.z) * (a.x + b.x)
            n.z += (a.x - b.x) * (a.y + b.y)
            c += a
        }
        let len = simd_length(n)
        guard len > 1e-14 else { return nil }
        n /= len
        return Plane3(normal: n, through: c / Double(loop.count))
    }
}

/// A right-handed coordinate system on a plane: sketch coordinates (x, y) plus a height along the normal.
public struct Frame3: Codable, Hashable, Sendable {
    public var origin: Vec3
    public var x: Vec3
    public var y: Vec3

    public init(origin: Vec3, x: Vec3, y: Vec3) {
        self.origin = origin
        self.x = x
        self.y = y
    }

    public var z: Vec3 { simd_cross(x, y) }
    public var plane: Plane3 { Plane3(normal: z, through: origin) }

    @inline(__always) public func world(_ p: Vec2, height: Double = 0) -> Vec3 {
        origin + x * p.x + y * p.y + z * height
    }

    @inline(__always) public func local(_ p: Vec3) -> Vec2 {
        let v = p - origin
        return Vec2(simd_dot(v, x), simd_dot(v, y))
    }

    @inline(__always) public func height(_ p: Vec3) -> Double { simd_dot(p - origin, z) }

    public static let xy = Frame3(origin: .zero, x: Vec3(1, 0, 0), y: Vec3(0, 1, 0))
    public static let xz = Frame3(origin: .zero, x: Vec3(1, 0, 0), y: Vec3(0, 0, 1))
    public static let yz = Frame3(origin: .zero, x: Vec3(0, 1, 0), y: Vec3(0, 0, 1))

    /// A frame on `plane` whose axes are chosen predictably, so a sketch on a face keeps its orientation
    /// when the model around it changes.
    public static func on(plane: Plane3, near point: Vec3) -> Frame3 {
        let n = plane.normal
        let origin = point - n * plane.distance(point)
        // Prefer a world axis for x: the first that isn't nearly parallel to the normal.
        let seed = abs(n.z) > 0.9 ? Vec3(1, 0, 0) : (abs(n.x) > 0.9 ? Vec3(0, 1, 0) : Vec3(1, 0, 0))
        let x = simd_normalize(seed - n * simd_dot(seed, n))
        return Frame3(origin: origin, x: x, y: simd_cross(n, x))
    }
}

public struct AABB: Codable, Hashable, Sendable {
    public var lo: Vec3
    public var hi: Vec3

    public static let empty = AABB(lo: Vec3(repeating: .infinity), hi: Vec3(repeating: -.infinity))

    public init(lo: Vec3, hi: Vec3) {
        self.lo = lo
        self.hi = hi
    }

    public init(points: some Sequence<Vec3>) {
        self = .empty
        for p in points { extend(p) }
    }

    public var isEmpty: Bool { lo.x > hi.x }
    public var center: Vec3 { (lo + hi) * 0.5 }
    public var size: Vec3 { isEmpty ? .zero : hi - lo }
    public var diagonal: Double { simd_length(size) }

    public mutating func extend(_ p: Vec3) {
        lo = simd_min(lo, p)
        hi = simd_max(hi, p)
    }

    public func union(_ o: AABB) -> AABB { AABB(lo: simd_min(lo, o.lo), hi: simd_max(hi, o.hi)) }

    @inline(__always) public func overlaps(_ o: AABB, tolerance: Double = 0) -> Bool {
        lo.x <= o.hi.x + tolerance && o.lo.x <= hi.x + tolerance
            && lo.y <= o.hi.y + tolerance && o.lo.y <= hi.y + tolerance
            && lo.z <= o.hi.z + tolerance && o.lo.z <= hi.z + tolerance
    }
}

extension Vec2 {
    @inline(__always) var length: Double { simd_length(self) }
    /// 2-D cross product: positive when `o` is counter-clockwise from self.
    @inline(__always) func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    @inline(__always) func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    /// Rotated 90° clockwise. For a loop walked counter-clockwise this points out of the region.
    @inline(__always) var rightNormal: Vec2 { Vec2(y, -x) }
}

/// Signed area of a 2-D loop: positive when counter-clockwise.
public func signedArea(_ loop: [Vec2]) -> Double {
    var a = 0.0
    for i in loop.indices {
        let p = loop[i], q = loop[(i + 1) % loop.count]
        a += p.cross(q)
    }
    return a / 2
}

public func pointInLoop(_ p: Vec2, _ loop: [Vec2]) -> Bool {
    var inside = false
    var j = loop.count - 1
    for i in loop.indices {
        let a = loop[i], b = loop[j]
        if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
        j = i
    }
    return inside
}

/// Number of straight pieces used to draw a full circle: chords stay within `chordTolerance` of the true curve.
public func circleSegments(radius: Double, chordTolerance: Double = 0.02) -> Int {
    guard radius > 0 else { return 24 }
    let step = 2 * acos(max(0, 1 - min(1, chordTolerance / radius)))
    guard step > 1e-6 else { return 128 }
    return min(128, max(24, Int((2 * .pi / step).rounded(.up))))
}

// MARK: - Triangulating polygons with holes

public enum Triangulator {
    /// Triangulates a 2-D polygon by ear clipping. `outer` is counter-clockwise, `holes` clockwise.
    /// Returns triples of indices into the concatenation outer + holes[0] + holes[1] + …
    public static func triangulate(outer: [Vec2], holes: [[Vec2]] = []) -> [Int32] {
        var points = outer
        var loop = Array(outer.indices)
        // Bridge each hole into the outer loop, rightmost hole first (Eberly's method).
        var offsets: [(hole: [Vec2], start: Int)] = []
        var start = outer.count
        for h in holes {
            offsets.append((h, start))
            points += h
            start += h.count
        }
        offsets.sort { ($0.hole.map(\.x).max() ?? 0) > ($1.hole.map(\.x).max() ?? 0) }
        for (hole, base) in offsets where hole.count >= 3 {
            let mi = hole.indices.max { hole[$0].x < hole[$1].x }!
            let m = hole[mi]
            let bridge = findBridge(from: m, loop: loop, points: points)
            var spliced: [Int] = []
            spliced.reserveCapacity(loop.count + hole.count + 2)
            spliced += loop[...bridge]
            for k in 0...hole.count { spliced.append(base + (mi + k) % hole.count) }
            spliced += loop[bridge...]
            loop = spliced
        }
        return clipEars(loop: loop, points: points)
    }

    /// Finds a loop vertex that the hole's rightmost point can see without crossing anything.
    private static func findBridge(from m: Vec2, loop: [Int], points: [Vec2]) -> Int {
        var bestX = Double.infinity
        var hitEdge = -1
        for i in loop.indices {
            let a = points[loop[i]], b = points[loop[(i + 1) % loop.count]]
            guard (a.y <= m.y && b.y >= m.y) || (b.y <= m.y && a.y >= m.y), a.y != b.y else { continue }
            let t = (m.y - a.y) / (b.y - a.y)
            let x = a.x + (b.x - a.x) * t
            if x >= m.x - 1e-12, x < bestX {
                bestX = x
                hitEdge = i
            }
        }
        guard hitEdge >= 0 else {
            // No wall to the right (degenerate input): connect to the nearest vertex instead.
            return loop.indices.min { simd_length_squared(points[loop[$0]] - m) < simd_length_squared(points[loop[$1]] - m) }!
        }
        let i0 = hitEdge, i1 = (hitEdge + 1) % loop.count
        let a = points[loop[i0]], b = points[loop[i1]]
        var candidate = a.x > b.x ? i0 : i1
        let hit = Vec2(bestX, m.y)
        let c = points[loop[candidate]]
        // Any reflex vertex inside triangle (m, hit, c) would block the view; choose the most direct one.
        var bestAngle = Double.infinity
        var bestDist = Double.infinity
        let triSign = (hit - m).cross(c - m)
        for i in loop.indices where i != candidate {
            let v = points[loop[i]]
            guard v.x >= m.x else { continue }
            let s1 = (hit - m).cross(v - m), s2 = (c - hit).cross(v - hit), s3 = (m - c).cross(v - c)
            let inside = triSign >= 0 ? (s1 >= 0 && s2 >= 0 && s3 >= 0) : (s1 <= 0 && s2 <= 0 && s3 <= 0)
            guard inside else { continue }
            let d = v - m
            let angle = abs(d.y) / max(d.length, 1e-30)
            if angle < bestAngle - 1e-12 || (abs(angle - bestAngle) <= 1e-12 && d.length < bestDist) {
                bestAngle = angle
                bestDist = d.length
                candidate = i
            }
        }
        // A vertex already used by an earlier bridge appears twice in the loop. Connecting to the wrong copy would
        // make the bridge cross the loop, so use the copy whose interior corner actually faces the hole.
        let target = points[loop[candidate]]
        for i in loop.indices where points[loop[i]] == target {
            let prev = points[loop[(i + loop.count - 1) % loop.count]], next = points[loop[(i + 1) % loop.count]]
            let toM = m - target
            let turn = (target - prev).cross(next - target)
            let leftOfNext = (next - target).cross(toM) >= 0, leftOfPrev = (target - prev).cross(toM) >= 0
            if turn >= 0 ? (leftOfNext && leftOfPrev) : (leftOfNext || leftOfPrev) { return i }
        }
        return candidate
    }

    private static func clipEars(loop input: [Int], points: [Vec2]) -> [Int32] {
        var loop = input
        var out: [Int32] = []
        out.reserveCapacity(max(0, loop.count - 2) * 3)
        @inline(__always) func corner(_ a: Int, _ b: Int, _ c: Int) -> Double {
            (points[b] - points[a]).cross(points[c] - points[a])
        }
        var i = 0
        var stalled = 0
        while loop.count > 3 {
            let n = loop.count
            let ia = (i + n - 1) % n, ib = i % n, ic = (i + 1) % n
            let a = loop[ia], b = loop[ib], c = loop[ic]
            let turn = corner(a, b, c)
            var isEar = turn > 1e-14
            if isEar {
                let ta = points[a], tb = points[b], tc = points[c]
                for k in loop where k != a && k != b && k != c {
                    let p = points[k]
                    // Vertices repeated by a hole bridge may touch the ear at its corners; that's allowed.
                    if p == ta || p == tb || p == tc { continue }
                    if (tb - ta).cross(p - ta) >= -1e-14, (tc - tb).cross(p - tb) >= -1e-14, (ta - tc).cross(p - tc) >= -1e-14 {
                        isEar = false
                        break
                    }
                }
            }
            // Collinear spikes can be dropped without emitting a triangle once nothing else fits.
            if isEar || stalled > n {
                if isEar || abs(turn) > 1e-14 {
                    out += [Int32(a), Int32(b), Int32(c)]
                }
                loop.remove(at: ib)
                stalled = 0
                i = ib
            } else {
                i = ib + 1
                stalled += 1
            }
        }
        if loop.count == 3, corner(loop[0], loop[1], loop[2]) > 1e-14 {
            out += [Int32(loop[0]), Int32(loop[1]), Int32(loop[2])]
        }
        return out
    }
}
