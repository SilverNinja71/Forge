import SwiftUI
import simd

/// Colours the brief asks for: blue while geometry can still move, black when fully constrained, red for conflicts.
enum SketchColors {
    static let free = Color(red: 0.05, green: 0.3, blue: 0.9)
    static let fixed = Color.black
    static let conflict = Color(red: 0.86, green: 0.1, blue: 0.1)
    static let construction = Color(white: 0.45)
    static let preview = Color(red: 0.98, green: 0.5, blue: 0.05)
}

/// Where a dimension's label sits, in sketch coordinates. Both drawing and clicking use this.
func dimensionLabelPosition(_ c: SketchConstraint, sketch: Sketch2D) -> Vec2? {
    func mid(_ a: Int, _ b: Int) -> Vec2 { (sketch.position(a) + sketch.position(b)) / 2 }
    switch c.kind {
    case .distance(let p, let q), .distanceX(let p, let q), .distanceY(let p, let q):
        return mid(p, q)
    case .pointLineDistance(let p, let line):
        guard let (a, b) = sketch.endpoints(of: line) else { return nil }
        return (sketch.position(p) + mid(a, b)) / 2
    case .offset(let l1, let l2), .angle(let l1, let l2):
        guard let a = sketch.endpoints(of: l1), let b = sketch.endpoints(of: l2) else { return nil }
        return (mid(a.a, a.b) + mid(b.a, b.b)) / 2
    case .radius(let curve), .diameter(let curve):
        guard let center = sketch.center(of: curve), let r = sketch.radius(of: curve) else { return nil }
        return sketch.position(center) + Vec2(r * 0.7071, r * 0.7071)
    default:
        return nil
    }
}

/// Shows a value in the document's units.
func formatLength(_ mm: Double, unitScale: Double) -> String {
    String(format: "%.3f", mm / unitScale).replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        + (unitScale == 25.4 ? " in" : " mm")
}

/// Draws the sketch being edited over the 3-D view: grid, curves in status colours, points, constraint marks,
/// dimension labels, snap hints and the shape a tool is about to make.
struct SketchOverlay: View {
    let editor: SketchEditor
    let frame: Frame3
    let camera: CadCamera
    let unitScale: Double

    var body: some View {
        // Copied to locals: Canvas's drawing closure isn't main-actor isolated.
        let editor = editor, frame = frame, camera = camera, unitScale = unitScale
        Canvas { ctx, size in
            func screen(_ p: Vec2) -> CGPoint { camera.project(frame.world(p), viewSize: size) }
            let sketch = editor.sketch
            let result = editor.result
            let mm = camera.viewHeight / Double(max(size.height, 1))

            // Grid: drawn at the snapping size, or coarser if that would be too dense to read.
            if var g = editor.grid.spacing {
                while g / mm < 7 { g *= 10 }
                let c0 = frame.local(camera.ray(at: .zero, viewSize: size).origin)
                let c1 = frame.local(camera.ray(at: CGPoint(x: size.width, y: size.height), viewSize: size).origin)
                let lo = simd_min(c0, c1), hi = simd_max(c0, c1)
                var path = Path(), major = Path()
                var x = (lo.x / g).rounded(.down) * g
                while x <= hi.x {
                    var line = Path()
                    line.move(to: screen(Vec2(x, lo.y)))
                    line.addLine(to: screen(Vec2(x, hi.y)))
                    if abs((x / (g * 10)).rounded() * g * 10 - x) < g * 0.01 { major.addPath(line) } else { path.addPath(line) }
                    x += g
                }
                var y = (lo.y / g).rounded(.down) * g
                while y <= hi.y {
                    var line = Path()
                    line.move(to: screen(Vec2(lo.x, y)))
                    line.addLine(to: screen(Vec2(hi.x, y)))
                    if abs((y / (g * 10)).rounded() * g * 10 - y) < g * 0.01 { major.addPath(line) } else { path.addPath(line) }
                    y += g
                }
                ctx.stroke(path, with: .color(.black.opacity(0.06)), lineWidth: 0.5)
                ctx.stroke(major, with: .color(.black.opacity(0.13)), lineWidth: 0.5)
            }
            // Sketch axes through the origin.
            var axes = Path()
            axes.move(to: screen(Vec2(-1e5, 0)))
            axes.addLine(to: screen(Vec2(1e5, 0)))
            ctx.stroke(axes, with: .color(.red.opacity(0.35)), lineWidth: 0.75)
            axes = Path()
            axes.move(to: screen(Vec2(0, -1e5)))
            axes.addLine(to: screen(Vec2(0, 1e5)))
            ctx.stroke(axes, with: .color(.green.opacity(0.4)), lineWidth: 0.75)

            // Curves.
            var conflicted = Set<Int>()
            for c in sketch.constraints where result.conflicting.contains(c.id) {
                conflicted.formUnion(c.kind.curveIDs)
                for p in c.kind.pointIDs {
                    for curve in sketch.curves where curve.pointIDs.contains(p) { conflicted.insert(curve.id) }
                }
            }
            for curve in sketch.curves {
                var path = Path()
                var first = true
                for e in sketch.tessellatedEdges(includeConstruction: true) where e.curve == curve.id {
                    if first {
                        path.move(to: screen(e.a))
                        first = false
                    }
                    path.addLine(to: screen(e.b))
                }
                let moving = curve.pointIDs.contains { result.freePoints.contains($0) } || result.freeRadii.contains(curve.id)
                var color = moving ? SketchColors.free : SketchColors.fixed
                if curve.isConstruction { color = SketchColors.construction }
                if conflicted.contains(curve.id) { color = SketchColors.conflict }
                let selected = editor.selection.curves.contains(curve.id)
                if selected { ctx.stroke(path, with: .color(.accentColor.opacity(0.45)), lineWidth: 5) }
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: curve.isConstruction ? [5, 4] : []))
            }

            // Points. The origin gets a ring.
            for p in sketch.points {
                let s = screen(p.position)
                let moving = result.freePoints.contains(p.id)
                let selected = editor.selection.points.contains(p.id)
                let r: CGFloat = selected ? 4 : 2.5
                let rect = CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)
                if p.id == Sketch2D.originID {
                    ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -2.5, dy: -2.5)), with: .color(.black), lineWidth: 1)
                }
                ctx.fill(Path(ellipseIn: rect), with: .color(selected ? .accentColor : (moving ? SketchColors.free : SketchColors.fixed)))
            }

            // Constraint marks beside the lines they apply to.
            func mark(_ text: String, at p: Vec2, offset: CGFloat, color: Color) {
                let s = screen(p)
                ctx.draw(Text(text).font(.system(size: 10, weight: .semibold)).foregroundColor(color), at: CGPoint(x: s.x + offset, y: s.y + offset))
            }
            for c in sketch.constraints {
                let color: Color = result.conflicting.contains(c.id) ? SketchColors.conflict : Color(white: 0.3)
                func midOf(_ line: Int) -> Vec2? {
                    guard let (a, b) = sketch.endpoints(of: line) else { return nil }
                    return (sketch.position(a) + sketch.position(b)) / 2
                }
                switch c.kind {
                case .horizontal(let l): if let m = midOf(l) { mark("H", at: m, offset: -9, color: color) }
                case .vertical(let l): if let m = midOf(l) { mark("V", at: m, offset: -9, color: color) }
                case .parallel(let a, let b):
                    if let m = midOf(a) { mark("∥", at: m, offset: 9, color: color) }
                    if let m = midOf(b) { mark("∥", at: m, offset: 9, color: color) }
                case .perpendicular(let a, let b):
                    if let m = midOf(a) { mark("⟂", at: m, offset: 9, color: color) }
                    if let m = midOf(b) { mark("⟂", at: m, offset: 9, color: color) }
                case .equal(let a, let b):
                    if let m = midOf(a) { mark("=", at: m, offset: 9, color: color) }
                    if let m = midOf(b) { mark("=", at: m, offset: 9, color: color) }
                case .tangent(let l, _, _):
                    if let m = midOf(l) { mark("T", at: m, offset: 9, color: color) }
                case .symmetric(let p, let q, _):
                    mark("⇋", at: sketch.position(p), offset: 9, color: color)
                    mark("⇋", at: sketch.position(q), offset: 9, color: color)
                case .fixed(let p, _):
                    mark("⚓︎", at: sketch.position(p), offset: 9, color: color)
                default:
                    break
                }
            }

            // Dimensions with their current values.
            for c in sketch.constraints {
                guard let d = c.dimension, let at = dimensionLabelPosition(c, sketch: sketch) else { continue }
                let value = c.kind.isAngular ? String(format: "%.2f°", d.value * 180 / .pi) : formatLength(d.value, unitScale: unitScale)
                let prefix: String
                switch c.kind {
                case .radius: prefix = "R "
                case .diameter: prefix = "Ø "
                default: prefix = ""
                }
                let conflict = result.conflicting.contains(c.id)
                let selected = editor.selection.constraint == c.id
                // Sits just below the line, leaving the H/V marks beside it readable.
                var s = screen(at)
                s.y += 13
                let label = ctx.resolve(Text("\(prefix)\(value)").font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(conflict ? SketchColors.conflict : .black))
                let box = label.measure(in: CGSize(width: 300, height: 40))
                let rect = CGRect(x: s.x - box.width / 2 - 4, y: s.y - box.height / 2 - 2, width: box.width + 8, height: box.height + 4)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(selected ? .accentColor.opacity(0.3) : .white.opacity(0.92)))
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(.black.opacity(0.2)), lineWidth: 0.5)
                ctx.draw(label, at: s)
            }

            // Tool preview and snap hints.
            if let cursor = editor.cursor, editor.tool != .select, editor.tool != .dimension {
                let cur = screen(cursor.position)
                var preview = Path()
                switch editor.tool {
                case .line:
                    if let last = editor.clicks.last {
                        preview.move(to: screen(last.position))
                        preview.addLine(to: cur)
                    }
                case .rectangle:
                    if let first = editor.clicks.first {
                        let a = first.position, b = cursor.position
                        preview.addLines([screen(a), screen(Vec2(b.x, a.y)), screen(b), screen(Vec2(a.x, b.y)), screen(a)])
                    }
                case .circle:
                    if let first = editor.clicks.first {
                        let r = simd_length(cursor.position - first.position) / mm
                        let c = screen(first.position)
                        preview.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                    }
                case .arc:
                    if editor.clicks.count == 1 {
                        preview.move(to: screen(editor.clicks[0].position))
                        preview.addLine(to: cur)
                    } else if editor.clicks.count == 2 {
                        let c = editor.clicks[0].position, s = editor.clicks[1].position
                        let r = simd_length(s - c)
                        let a0 = atan2(s.y - c.y, s.x - c.x)
                        var sweep = atan2(cursor.position.y - c.y, cursor.position.x - c.x) - a0
                        if sweep <= 0 { sweep += 2 * .pi }
                        preview.move(to: screen(s))
                        for k in 1...48 {
                            let a = a0 + sweep * Double(k) / 48
                            preview.addLine(to: screen(c + Vec2(cos(a), sin(a)) * r))
                        }
                    }
                default:
                    break
                }
                ctx.stroke(preview, with: .color(SketchColors.preview), style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))

                // Inference line and snap marker.
                if let inferred = cursor.inferred, let last = editor.clicks.last {
                    var guide = Path()
                    guide.move(to: screen(last.position))
                    guide.addLine(to: cur)
                    ctx.stroke(guide, with: .color(.green), lineWidth: 1)
                    ctx.draw(Text(inferred == .horizontal ? "H" : "V").font(.system(size: 10, weight: .bold)).foregroundColor(.green),
                             at: CGPoint(x: cur.x + 12, y: cur.y - 12))
                }
                switch cursor.kind {
                case .existingPoint:
                    ctx.stroke(Path(ellipseIn: CGRect(x: cur.x - 6, y: cur.y - 6, width: 12, height: 12)), with: .color(SketchColors.preview), lineWidth: 1.5)
                case .midpoint:
                    var tri = Path()
                    tri.move(to: CGPoint(x: cur.x, y: cur.y - 6))
                    tri.addLine(to: CGPoint(x: cur.x + 6, y: cur.y + 4))
                    tri.addLine(to: CGPoint(x: cur.x - 6, y: cur.y + 4))
                    tri.closeSubpath()
                    ctx.stroke(tri, with: .color(SketchColors.preview), lineWidth: 1.5)
                default:
                    ctx.fill(Path(ellipseIn: CGRect(x: cur.x - 3, y: cur.y - 3, width: 6, height: 6)), with: .color(SketchColors.preview))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small compass in the corner showing which way the world's axes point.
struct OrientationGizmo: View {
    let camera: CadCamera

    var body: some View {
        let camera = camera
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let len = min(size.width, size.height) * 0.38
            let axes: [(Vec3, Color, String)] = [(Vec3(1, 0, 0), .red, "X"), (Vec3(0, 1, 0), .green, "Y"), (Vec3(0, 0, 1), .blue, "Z")]
            // Far axes first so nearer ones draw on top.
            for (a, color, name) in axes.sorted(by: { simd_dot($0.0, camera.back) < simd_dot($1.0, camera.back) }) {
                let tip = CGPoint(x: c.x + simd_dot(a, camera.right) * len, y: c.y - simd_dot(a, camera.up) * len)
                var p = Path()
                p.move(to: c)
                p.addLine(to: tip)
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ctx.draw(Text(name).font(.system(size: 10, weight: .bold)).foregroundColor(color),
                         at: CGPoint(x: tip.x + (tip.x - c.x) * 0.22, y: tip.y + (tip.y - c.y) * 0.22))
            }
        }
        .allowsHitTesting(false)
    }
}
