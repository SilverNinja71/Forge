import Foundation
import simd
import CoreGraphics

/// The orthographic camera engineers expect: parallel lines stay parallel on screen.
public struct CadCamera: Equatable, Sendable {
    /// The world point at the centre of the view.
    public var target = Vec3.zero
    /// Camera orientation: its local x is screen right, y is screen up, z points out of the screen at you.
    public var rotation = CadCamera.isoRotation
    /// How many millimetres the viewport's height shows.
    public var viewHeight = 120.0

    public init() {}

    /// The classic three-quarter view: Z up, looking down at the XY plane from the front right.
    public static let isoRotation: simd_quatd = {
        let z = simd_quatd(angle: 35 * .pi / 180, axis: Vec3(0, 0, 1))
        let x = simd_quatd(angle: 62 * .pi / 180, axis: Vec3(1, 0, 0))
        return simd_normalize(z * x)
    }()

    public var right: Vec3 { rotation.act(Vec3(1, 0, 0)) }
    public var up: Vec3 { rotation.act(Vec3(0, 1, 0)) }
    /// Direction from the scene towards the viewer.
    public var back: Vec3 { rotation.act(Vec3(0, 0, 1)) }

    public mutating func orbit(dx: Double, dy: Double) {
        // Turntable: left/right spins about the world's vertical, up/down tilts about the screen's horizontal.
        let spin = simd_quatd(angle: -dx * 0.008, axis: Vec3(0, 0, 1))
        let tilt = simd_quatd(angle: -dy * 0.008, axis: right)
        rotation = simd_normalize(spin * tilt * rotation)
    }

    public mutating func pan(dx: Double, dy: Double, viewSize: CGSize) {
        let mmPerPoint = viewHeight / Double(max(viewSize.height, 1))
        target += right * (-dx * mmPerPoint) + up * (dy * mmPerPoint)
    }

    /// Zooms keeping the world point under the cursor exactly where it is on screen.
    public mutating func zoom(factor: Double, at point: CGPoint, viewSize: CGSize) {
        let before = worldOnTargetPlane(point, viewSize: viewSize)
        viewHeight = min(max(viewHeight * factor, 0.01), 100_000)
        let after = worldOnTargetPlane(point, viewSize: viewSize)
        target += before - after
    }

    private func worldOnTargetPlane(_ p: CGPoint, viewSize: CGSize) -> Vec3 {
        let mm = viewHeight / Double(max(viewSize.height, 1))
        let sx = (Double(p.x) - Double(viewSize.width) / 2) * mm
        let sy = (Double(viewSize.height) / 2 - Double(p.y)) * mm
        return target + right * sx + up * sy
    }

    /// Looks straight at a plane, with its x axis pointing right.
    public mutating func look(along frame: Frame3) {
        let m = simd_double3x3(columns: (frame.x, frame.y, frame.z))
        rotation = simd_normalize(simd_quatd(m))
        target = frame.origin + (target - frame.origin) - frame.z * simd_dot(target - frame.origin, frame.z)
    }

    public mutating func frame(_ box: AABB, viewSize: CGSize) {
        guard !box.isEmpty else { return }
        target = box.center
        var w = 0.0, h = 0.0
        for x in [box.lo.x, box.hi.x] {
            for y in [box.lo.y, box.hi.y] {
                for z in [box.lo.z, box.hi.z] {
                    let v = Vec3(x, y, z) - box.center
                    w = max(w, abs(simd_dot(v, right)))
                    h = max(h, abs(simd_dot(v, up)))
                }
            }
        }
        let aspect = Double(viewSize.width / max(viewSize.height, 1))
        viewHeight = max(2 * max(h, w / max(aspect, 0.01)) * 1.25, 0.1)
    }

    /// World → points on screen (origin top-left).
    public func project(_ p: Vec3, viewSize: CGSize) -> CGPoint {
        let mm = viewHeight / Double(max(viewSize.height, 1))
        let v = p - target
        return CGPoint(x: Double(viewSize.width) / 2 + simd_dot(v, right) / mm,
                       y: Double(viewSize.height) / 2 - simd_dot(v, up) / mm)
    }

    /// A screen point as a ray: every world point under that pixel is origin + t·direction.
    public func ray(at p: CGPoint, viewSize: CGSize) -> (origin: Vec3, direction: Vec3) {
        (worldOnTargetPlane(p, viewSize: viewSize), -back)
    }

    /// Clip-space transform. Depth spans the model generously so nothing is cut off while orbiting.
    public func viewProjection(aspect: Double, depthRange: Double) -> simd_float4x4 {
        let halfH = viewHeight / 2, halfW = halfH * aspect
        let range = max(depthRange, 1)
        let r = right, u = up, b = back
        // Metal's clip z runs 0...1; near things have smaller z.
        func col(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> SIMD4<Float> {
            SIMD4(Float(x), Float(y), Float(z), Float(w))
        }
        let t = target
        return simd_float4x4(columns: (
            col(r.x / halfW, u.x / halfH, -b.x / (2 * range), 0),
            col(r.y / halfW, u.y / halfH, -b.y / (2 * range), 0),
            col(r.z / halfW, u.z / halfH, -b.z / (2 * range), 0),
            col(-simd_dot(r, t) / halfW, -simd_dot(u, t) / halfH, 0.5 + simd_dot(b, t) / (2 * range), 1)
        ))
    }
}
