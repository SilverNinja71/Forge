// Headless end-to-end check of Forge: drives the real click handling, solver, feature tree and renderer through
// modelling a bracket, checks the numbers, saves and reopens, syncs to a local "cloud" and screenshots each
// screen, all without putting a window on screen.
//
//   swift build -c release --product ForgeSnapshots && .build/release/ForgeSnapshots <output-dir>

import Foundation
import AppKit
import SwiftUI
import MetalKit
import simd
import ForgeCore
import CommonKit

let iconMode = CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--icon"
let outDir = URL(fileURLWithPath: iconMode ? NSTemporaryDirectory() : (CommandLine.arguments.dropFirst().first ?? "snapshots"), isDirectory: true)
if !iconMode { try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }
var failures = 0

func check(_ ok: Bool, _ what: String) {
    print(ok ? "✓ \(what)" : "✗ FAIL \(what)")
    if !ok { failures += 1 }
}

func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }

func time(_ body: () -> Void) -> Double {
    let t0 = CFAbsoluteTimeGetCurrent()
    body()
    return (CFAbsoluteTimeGetCurrent() - t0) * 1000
}

func writePNG(_ image: CGImage?, _ name: String) {
    guard let image else { check(false, "render \(name)"); return }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
}

@MainActor
func snapshotView<V: View>(_ view: V, size: CGSize, name: String) {
    let root = view
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.forgeSnapshotMode, true)
        .environment(\.colorScheme, .light)
    let host = NSHostingView(rootView: root)
    host.sizingOptions = []
    host.frame = CGRect(origin: .zero, size: size)
    // An off-screen window gives SwiftUI a real view hierarchy; it is never ordered on screen.
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { check(false, "screenshot \(name)"); return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
    window.contentView = nil
}

func waitFor(_ body: @escaping @MainActor () async -> Void) {
    var done = false
    Task { @MainActor in await body(); done = true }
    while !done { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
}

/// Fraction of an image's pixels satisfying a test. Used to check a render actually shows what it should.
func pixelFraction(_ image: CGImage?, _ test: (_ r: Double, _ g: Double, _ b: Double) -> Bool) -> Double {
    guard let image, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
    var hits = 0, total = 0
    let w = image.width, h = image.height, row = image.bytesPerRow
    for y in stride(from: 0, to: h, by: 3) {
        for x in stride(from: 0, to: w, by: 3) {
            let p = y * row + x * 4
            // BGRA.
            if test(Double(bytes[p + 2]) / 255, Double(bytes[p + 1]) / 255, Double(bytes[p]) / 255) { hits += 1 }
            total += 1
        }
    }
    return Double(hits) / Double(max(total, 1))
}

let workspaceSize = CGSize(width: 1440, height: 900)

/// Clicks the same way a person would, through the interaction controller, at the screen position of a model point.
@MainActor
struct Driver {
    let doc: CadDocument
    let controller: CadInteractionController

    func sketchFrame() -> Frame3 { doc.frameForSketch(doc.editingSketchID!)! }

    func click(_ p: Vec2, extend: Bool = false) {
        let at = doc.camera.project(sketchFrame().world(p), viewSize: controller.viewSize)
        controller.hover(at: at)
        controller.primaryDown(at: at, extend: extend)
        controller.primaryUp()
    }

    func click3D(_ p: Vec3, extend: Bool = false) {
        let at = doc.camera.project(p, viewSize: controller.viewSize)
        controller.primaryDown(at: at, extend: extend)
        controller.primaryUp()
    }

    func tool(_ t: SketchTool) { _ = controller.perform(.tool(t)) }

    /// Clicks with the dimension tool, then types a value into the box that appears.
    func dimension(click p: Vec2, _ expression: String) -> Bool {
        doc.editor?.tool = .dimension
        click(p)
        return doc.commitDimension(expression: expression)
    }

    func dimension(_ kind: SketchConstraint.Kind, _ expression: String) -> Bool {
        doc.editor?.pendingDimension = SketchEditor.PendingDimension(kind: kind, suggested: expression, at: .zero)
        return doc.commitDimension(expression: expression)
    }
}

@MainActor
func screenshotWorkspace(_ model: ForgeAppModel, _ doc: CadDocument, _ name: String) {
    snapshotView(ForgeWorkspaceView(model: model, document: doc), size: workspaceSize, name: name)
}

// MARK: - The walkthrough

@MainActor
func run() throws {
    let root = outDir.appendingPathComponent("gallery")
    try? FileManager.default.removeItem(at: root)
    let model = ForgeAppModel(galleryFolder: root)
    guard let renderer = model.renderer else { check(false, "Metal renderer starts"); return }
    check(true, "Metal renderer starts on \(renderer.device.name)")
    model.newDocument(name: "Bracket")
    let doc = model.document!
    let controller = CadInteractionController(document: doc)
    controller.viewSize = CGSize(width: 936, height: 762)
    let drive = Driver(doc: doc, controller: controller)

    // Parameters drive everything downstream.
    doc.setParameter("width", expression: "60mm")
    doc.setParameter("depth", expression: "width * 2 / 3")
    doc.camera.target = Vec3(30, 20, 0)
    doc.camera.viewHeight = 100

    // Sketch: a rectangle drawn with real clicks, starting on the origin. The L/R/C keys start a sketch on XY.
    drive.tool(.rectangle)
    check(doc.editingSketchID != nil, "pressing R starts a sketch")
    doc.camera.target = Vec3(30, 20, 0)
    drive.click(Vec2(0, 0))
    drive.click(Vec2(50, 30))
    let draftLines = doc.editor!.sketch.curves.map(\.id)
    check(draftLines.count == 4, "two clicks draw a four-sided rectangle")
    check(doc.editor!.result.status == .underConstrained && doc.editor!.result.degreesOfFreedom == 2,
          "rectangle tied to the origin is blue with 2 degrees of freedom (got \(doc.editor!.result.degreesOfFreedom))")
    screenshotWorkspace(model, doc, "01-sketch-under-constrained-blue.png")

    // Dimensions: click a line, type a formula.
    check(drive.dimension(click: Vec2(25, 0), "width"), "dimension box accepts the formula “width”")
    check(drive.dimension(click: Vec2(60, 15), "depth"), "dimension box accepts the formula “depth”")
    let solved = doc.editor!
    check(solved.result.status == .fullyConstrained, "dimensioned rectangle is fully constrained (black)")
    check(solved.result.residual < 1e-6, "solver is sub-micron accurate: error \(String(format: "%.1e", solved.result.residual)) mm")
    screenshotWorkspace(model, doc, "02-sketch-fully-constrained-black.png")

    // Over-constraining goes red, and removing the extra constraint recovers.
    doc.editor?.tool = .select
    drive.click(Vec2(30, 0))
    drive.click(Vec2(30, 40), extend: true)
    check(doc.editor!.availableConstraints.contains { $0.name == "Parallel" }, "selecting two lines offers Parallel")
    doc.editor?.applyConstraint(named: "Parallel")
    check(doc.editor!.result.status == .overConstrained, "a redundant constraint turns the sketch red")
    screenshotWorkspace(model, doc, "03-sketch-over-constrained-red.png")
    let extraConstraint = doc.editor!.sketch.constraints.last!.id
    doc.editor?.removeConstraint(extraConstraint)
    check(doc.editor!.result.status == .fullyConstrained, "removing it turns the sketch black again")
    doc.finishSketch()

    // Extrude with a live preview.
    _ = controller.perform(.extrude)
    guard case .extrude(var extrude, _)? = doc.activeCommand else { check(false, "E opens the extrude panel"); return }
    extrude.extent = .blind("12mm")
    doc.activeCommand = .extrude(extrude, editing: nil)
    doc.updateCommandPreview()
    check(doc.displayBodies.count == 1 && doc.bodies.isEmpty, "extrude previews before it's confirmed")
    doc.resetView()
    screenshotWorkspace(model, doc, "04-extrude-preview.png")
    doc.commitCommand()
    let baseID = doc.tree.features.last!.id
    let plateVolume = 60.0 * 40 * 12
    check(near(doc.bodies[0].solid.massProperties().volume, plateVolume), "extruded plate has the exact volume (28800 mm³)")

    // Click the top face, then press C: a sketch on that face. Draw a circle and tie it to the middle of the plate.
    doc.resetView()
    drive.click3D(Vec3(30, 20, 12))
    check(doc.selection.faces == [FaceTag(feature: baseID, role: .endCap)], "clicking the top face picks it by name")
    screenshotWorkspace(model, doc, "05-face-selected.png")
    drive.tool(.circle)
    guard case .sketch(let holeSketch)? = doc.tree.feature(doc.editingSketchID ?? -1)?.kind, case .face = holeSketch.plane else {
        check(false, "pressing C with a face selected sketches on it")
        return
    }
    drive.click(Vec2(30, 20))
    drive.click(Vec2(38, 20))
    check(doc.editor!.sketch.curves.count == 1, "two clicks draw a circle")
    let circle = doc.editor!.sketch.curves[0].id
    let center = doc.editor!.sketch.center(of: circle)!
    check(drive.dimension(click: Vec2(38, 20), "16mm"), "clicking the circle offers its diameter")
    check(drive.dimension(.distanceX(p: Sketch2D.originID, q: center), "width / 2"), "hole centre x = width / 2")
    check(drive.dimension(.distanceY(p: Sketch2D.originID, q: center), "depth / 2"), "hole centre y = depth / 2")
    check(doc.editor!.result.status == .fullyConstrained, "hole sketch is fully constrained")
    doc.finishSketch()

    // Cut straight through.
    doc.beginExtrude()
    if case .extrude(var cut, _)? = doc.activeCommand {
        cut.extent = .throughAll
        cut.flip = true
        cut.operation = .cut
        doc.activeCommand = .extrude(cut, editing: nil)
        doc.commitCommand()
    }
    let holed = doc.bodies[0].solid
    check(holed.isClosed, "cut body is still watertight")
    check(!holed.contains(Vec3(30, 20, 6)) && holed.contains(Vec3(10, 10, 6)), "the hole is empty and the plate around it isn't")

    // Fillet: click four edges on screen. A preview follows every click.
    _ = controller.perform(.fillet)
    for p in [Vec3(30, 0, 12), Vec3(60, 20, 12), Vec3(30, 40, 12), Vec3(0, 20, 12)] { drive.click3D(p) }
    check(doc.selection.edges.count == 4, "clicking four edges on screen picks all four")
    screenshotWorkspace(model, doc, "06-fillet-preview.png")
    doc.commitCommand()
    let filletID = doc.tree.features.last!.id
    check(doc.regeneration.errors[filletID] == nil && doc.bodies[0].solid.isClosed, "fillet succeeds and stays watertight")
    let filleted = doc.bodies[0].solid
    check(!filleted.contains(Vec3(0.25, 20, 11.75)) && !filleted.contains(Vec3(59.75, 20, 11.75)), "the fillet landed on the top edges that were clicked")
    check(filleted.contains(Vec3(0.25, 20, 0.25)) && filleted.contains(Vec3(59.75, 20, 0.25)), "the bottom edges behind them were left alone")

    // Chamfer the rim of the hole: a closed curved edge.
    doc.beginChamfer()
    drive.click3D(Vec3(38, 20, 12))
    check(doc.selection.edges.count == 1, "clicking the hole's rim picks it")
    doc.commitCommand()
    let chamferID = doc.tree.features.last!.id
    check(doc.regeneration.errors[chamferID] == nil && doc.bodies[0].solid.isClosed, "chamfering the rim succeeds and stays watertight")
    check(doc.bodies[0].solid.tags.contains { $0.role == .chamfer }, "the chamfer's face is in the model")
    check(!doc.bodies[0].solid.contains(Vec3(38.2, 20, 11.9)) && doc.bodies[0].solid.contains(Vec3(38.2, 20, 0.1)), "the chamfer is on the top of the hole, as clicked")
    doc.selection = ModelSelection()
    doc.hoverEdge = nil
    screenshotWorkspace(model, doc, "07-finished-part.png")

    let baseVolume = doc.bodies[0].solid.massProperties().volume

    // The parametric promise: change one number and everything follows.
    var cascadeError = false
    let regenMs = time { doc.setParameter("width", expression: "90mm") }
    cascadeError = !doc.regeneration.errors.isEmpty
    let wide = doc.bodies[0].solid
    check(!cascadeError, "changing width regenerates without errors")
    check(near(wide.bounds.size.x, 90) && near(wide.bounds.size.y, 60), "plate became 90 × 60 (depth follows width by formula)")
    check(!wide.contains(Vec3(45, 30, 6)) && wide.contains(Vec3(30, 20, 6)), "hole moved to the new centre")
    check(wide.tags.contains { $0.role == .fillet } && wide.tags.contains { $0.role == .chamfer }, "fillet and chamfer re-found their edges")
    print("  full regeneration after a parameter change: \(String(format: "%.0f", regenMs)) ms")
    doc.frameAll()
    screenshotWorkspace(model, doc, "08-after-changing-width.png")

    // Undo / redo / rollback.
    doc.undo()
    check(near(doc.bodies[0].solid.massProperties().volume, baseVolume), "undo restores the model")
    doc.redo()
    check(near(doc.bodies[0].solid.bounds.size.x, 90), "redo re-applies the change")
    doc.undo()
    doc.setRollback(2)
    check(near(doc.bodies[0].solid.massProperties().volume, plateVolume), "rolling back the timeline shows the plain plate")
    doc.setRollback(nil)
    check(near(doc.bodies[0].solid.massProperties().volume, baseVolume), "rolling forward brings every feature back")

    // Suppressing a feature.
    doc.setSuppressed(chamferID, true)
    check(!doc.bodies[0].solid.tags.contains { $0.role == .chamfer }, "suppressing removes the chamfer")
    doc.setSuppressed(chamferID, false)

    // Broken dependency: a fillet that no longer fits is reported, not fatal.
    doc.editFeature(filletID)
    if case .fillet(_, let id)? = doc.activeCommand {
        doc.activeCommand = .fillet(radius: "500mm", editing: id)
        doc.updateCommandPreview()
        check(doc.previewError?.contains("too large") == true, "an oversized fillet is refused with a reason")
        doc.cancelCommand()
    }
    doc.selection = ModelSelection()

    // Display modes.
    doc.resetView()
    func render(_ mode: DisplayMode, section: Bool = false) -> CGImage? {
        doc.viewport.mode = mode
        doc.viewport.section.isEnabled = section
        return renderer.renderImage(doc.scene, width: 1200, height: 900)
    }
    let background = { (r: Double, g: Double, b: Double) in r > 0.78 && g > 0.8 && b > 0.82 && abs(r - b) < 0.06 }
    var frameMs = 0.0
    frameMs = time { _ = render(.shadedEdges) }
    let shaded = render(.shaded)
    writePNG(shaded, "10-mode-shaded.png")
    check(pixelFraction(shaded) { !background($0, $1, $2) } > 0.1, "shaded render shows the part")
    let edges = render(.shadedEdges)
    writePNG(edges, "11-mode-shaded-edges.png")
    check(pixelFraction(edges) { $0 < 0.2 && $1 < 0.2 && $2 < 0.2 } > 0.002, "edge lines are drawn")
    writePNG(render(.hiddenLine), "12-mode-hidden-line.png")
    let wire = render(.wireframe)
    writePNG(wire, "13-mode-wireframe.png")
    let zebra = render(.zebra)
    writePNG(zebra, "14-mode-zebra.png")
    let dark = pixelFraction(zebra) { $0 < 0.25 && $1 < 0.25 && $2 < 0.25 }, light = pixelFraction(zebra) { $0 > 0.9 && $1 > 0.9 && $2 > 0.9 }
    check(dark > 0.002 && light > 0.01, "zebra view shows both dark and light stripes")
    doc.viewport.pullDirection = Vec3(0, 0, 1)
    let draft = render(.draftAnalysis)
    writePNG(draft, "15-mode-draft-analysis.png")
    check(pixelFraction(draft) { $1 > $0 + 0.15 && $1 > $2 + 0.15 } > 0.02, "draft analysis colours the pull-facing top green")
    doc.viewport.section.axis = 1
    doc.viewport.section.offset = 20
    doc.viewport.section.flipped = true
    doc.viewport.showGrid = false
    let cut = render(.shadedEdges, section: true)
    writePNG(cut, "16-section-cut.png")
    check(pixelFraction(cut) { $0 > 0.55 && $1 < 0.6 && $2 < 0.5 && $0 > $2 + 0.15 } > 0.005, "section view paints a hatched cap on the cut")
    doc.viewport.showGrid = true
    print("  frame at 1200×900 with read-back: \(String(format: "%.1f", frameMs)) ms")
    doc.viewport.mode = .shadedEdges
    doc.activeCommand = .inspect
    screenshotWorkspace(model, doc, "17-inspect-and-section.png")
    doc.viewport.section.isEnabled = false
    doc.activeCommand = nil

    // Inspection against textbook values: a separate 20 mm cube, 10 mm away from the plate's corner.
    var probeTree = FeatureTree()
    var cube = Sketch2D()
    cube.addRectangle(Vec2(-30, 0), Vec2(-10, 20))
    let cubeSketch = probeTree.append(.sketch(SketchFeature(plane: .xy, sketch: cube)))
    _ = probeTree.append(.extrude(ExtrudeFeature(sketchID: cubeSketch, extent: .blind("20mm"))))
    let probe = probeTree.regenerate().final.bodies[0].solid
    let m = probe.massProperties()
    check(near(m.volume, 8000) && near(m.surfaceArea, 2400), "inspection: a 20 mm cube measures 8000 mm³, 2400 mm²")
    check(simd_length(m.centerOfMass - Vec3(-20, 10, 10)) < 1e-9, "inspection: its centre of mass is at its middle")
    check(near(m.inertia[0], 8000 * 800 / 12, 1e-3), "inspection: its moment of inertia matches V·(a²+b²)/12")
    check(near(probe.minimumDistance(to: doc.bodies[0].solid).distance, 10, 1e-6), "inspection: minimum distance to the plate is 10 mm")

    // Keyboard: the whole table from the brief.
    let keyChecks: [(String, ForgeKeyAction)] = [("c", .tool(.circle)), ("r", .tool(.rectangle)), ("l", .tool(.line)), ("d", .tool(.dimension)),
                                                 ("e", .extrude), ("q", .pressPull), ("f", .fillet), ("m", .moveCopy), ("s", .commandSearch)]
    check(keyChecks.allSatisfy { ForgeKeymap.action(for: $0.0) == $0.1 }, "shortcuts C R L D E Q F M S are all mapped")

    // Camera: scroll zooms at the cursor, keeping what's under it in place.
    let probePoint = CGPoint(x: 700, y: 200)
    let before = doc.camera.ray(at: probePoint, viewSize: controller.viewSize).origin
    controller.zoom(factor: 0.5, at: probePoint)
    let after = doc.camera.ray(at: probePoint, viewSize: controller.viewSize).origin
    check(simd_length(before - after) < 1e-9, "zoom keeps the point under the cursor still")
    doc.resetView()

    // Files: save, delta save, reopen, mesh cache, STL.
    model.saveNow()
    let url = doc.fileURL!
    let fm = FileManager.default
    check(fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) && fm.fileExists(atPath: url.appendingPathComponent("model.json").path)
          && fm.fileExists(atPath: url.appendingPathComponent("mesh/bodies.bin").path) && fm.fileExists(atPath: url.appendingPathComponent("thumbnail.png").path),
          "project saves as a .forge package with manifest, model, mesh and thumbnail")
    let delta = try doc.save(to: url, thumbnail: model.thumbnail(for: doc))
    check(delta == ["manifest.json"], "saving again rewrites only the manifest (delta save, got \(delta))")
    let reopened = try CadDocument.open(url)
    check(reopened.tree == doc.tree, "reopened feature tree is identical")
    check(near(reopened.bodies[0].solid.massProperties().volume, doc.bodies[0].solid.massProperties().volume, 1e-9), "reopened model recomputes to the same volume")
    let cache = try Data(contentsOf: url.appendingPathComponent("mesh/bodies.bin"))
    check(ForgeMeshCache.triangleCounts(cache) == doc.bodies.map(\.solid.triangleCount), "mesh cache matches the model")
    let stl = STLExporter.data(for: doc.bodies)
    check(stl.count == 84 + doc.bodies[0].solid.triangleCount * 50, "STL export has the right size for its triangles")
    try stl.write(to: outDir.appendingPathComponent("bracket.stl"))

    // A second part: revolve + shell + zebra.
    model.closeDocument()
    model.newDocument(name: "Flask")
    let flask = model.document!
    var profile = Sketch2D()
    // Half of a flask's outline, in the XZ plane, spun around the sketch's Y axis (the world's Z).
    let pts = [Vec2(0, 0), Vec2(25, 0), Vec2(25, 40), Vec2(10, 60), Vec2(10, 80), Vec2(0, 80)]
    let ids = pts.map { profile.addPoint($0) }
    var lines: [Int] = []
    for i in ids.indices { lines.append(profile.addLine(from: ids[i], to: ids[(i + 1) % ids.count])) }
    var sketchID = 0
    flask.edit { t in sketchID = t.append(.sketch(SketchFeature(plane: .xz, sketch: profile))) }
    flask.beginRevolve()
    flask.commitCommand()
    let revolveID = flask.tree.features.last!.id
    check(flask.bodies.count == 1 && flask.bodies[0].solid.isClosed, "revolve makes a closed solid")
    flask.edit { t in
        _ = t.append(.fillet(FilletFeature(edges: [EdgeRef(a: FaceTag(feature: revolveID, role: .side, entity: lines[2]), b: FaceTag(feature: revolveID, role: .side, entity: lines[3]))], radius: "6mm")))
    }
    check(flask.regeneration.errors.isEmpty && flask.bodies[0].solid.isClosed, "filleting the flask's shoulder (a circular concave edge) works")
    flask.edit { t in
        _ = t.append(.shell(ShellFeature(openFaces: [FaceTag(feature: revolveID, role: .side, entity: lines[4])], thickness: "2mm")))
    }
    check(flask.regeneration.errors.isEmpty, "shelling the flask works: \(flask.regeneration.errors.values.first ?? "ok")")
    check(!flask.bodies[0].solid.contains(Vec3(0, 0, 30)), "the flask is hollow")
    check(flask.bodies[0].solid.contains(Vec3(24, 0, 20)), "the flask's wall is solid")
    flask.resetView()
    flask.viewport.showSketches = false
    flask.viewport.mode = .zebra
    writePNG(renderer.renderImage(flask.scene, width: 1000, height: 900), "20-flask-zebra.png")
    flask.viewport.mode = .shadedEdges
    flask.viewport.section.isEnabled = true
    flask.viewport.section.axis = 1
    flask.viewport.section.offset = 0
    flask.viewport.section.flipped = true
    flask.viewport.showGrid = false
    writePNG(renderer.renderImage(flask.scene, width: 1000, height: 900), "21-flask-section.png")
    flask.viewport = ViewportSettings()
    model.saveNow()

    // Loft and sweep through the feature tree.
    model.closeDocument()
    model.newDocument(name: "Transitions")
    let shapes = model.document!
    shapes.edit { t in
        var a = Sketch2D()
        a.addRectangle(Vec2(-15, -15), Vec2(15, 15))
        let low = t.append(.sketch(SketchFeature(plane: .xy, sketch: a)))
        var b = Sketch2D()
        b.addCircle(center: Vec2(0, 0), radius: 10)
        let high = t.append(.sketch(SketchFeature(plane: .offset(base: 0, distance: "40mm"), sketch: b)))
        _ = t.append(.loft(LoftFeature(sketchIDs: [low, high])))
        var p = Sketch2D()
        p.addCircle(center: Vec2(50, 0), radius: 3)
        let prof = t.append(.sketch(SketchFeature(plane: .xy, sketch: p)))
        var path = Sketch2D()
        path.addLine(Vec2(50, 0), Vec2(50, 25))
        path.addLine(Vec2(50, 25), Vec2(70, 40))
        let pathID = t.append(.sketch(SketchFeature(plane: .xz, sketch: path)))
        _ = t.append(.sweep(SweepFeature(profileSketchID: prof, pathSketchID: pathID)))
    }
    check(shapes.regeneration.errors.isEmpty, "loft and sweep build: \(shapes.regeneration.errors.values.first ?? "ok")")
    check(shapes.bodies.count == 2 && shapes.bodies.allSatisfy { $0.solid.isClosed }, "loft and sweep are each a closed body")
    shapes.resetView()
    writePNG(renderer.renderImage(shapes.scene, width: 1200, height: 800), "22-loft-and-sweep.png")
    model.saveNow()

    // Stress: a plate with a grid of holes, all driven by one number.
    var stress = FeatureTree()
    stress.parameters = [Parameter(name: "hole", expression: "3mm")]
    var plate = Sketch2D()
    plate.addRectangle(Vec2(0, 0), Vec2(120, 120))
    let plateSketch = stress.append(.sketch(SketchFeature(plane: .xy, sketch: plate)))
    _ = stress.append(.extrude(ExtrudeFeature(sketchID: plateSketch, extent: .blind("6mm"))))
    var holes = Sketch2D()
    var hn = 1
    for i in 0..<6 {
        for j in 0..<6 {
            let c = holes.addCircle(center: Vec2(10 + Double(i) * 20, 10 + Double(j) * 20), radius: 3)
            holes.addConstraint(.radius(curve: c), dimension: SketchDimension(name: "h\(hn)", expression: "hole", value: 3))
            hn += 1
        }
    }
    let holeSk = stress.append(.sketch(SketchFeature(plane: .xy, sketch: holes)))
    _ = stress.append(.extrude(ExtrudeFeature(sketchID: holeSk, extent: .throughAll, operation: .cut)))
    var heavy = FeatureTree.Regeneration()
    let heavyMs = time { heavy = stress.regenerate() }
    let heavySolid = heavy.final.bodies[0].solid
    let expected: Double = 120 * 120 * 6 - 36 * Double.pi * 9 * 6
    check(heavy.errors.isEmpty && heavySolid.isClosed && abs(heavySolid.massProperties().volume - expected) / expected < 0.002,
          "a plate with 36 holes stays watertight and has the right volume")
    print("  36-hole plate regenerates in \(String(format: "%.0f", heavyMs)) ms (\(heavySolid.triangleCount) triangles)")
    var heavyCam = CadCamera()
    heavyCam.frame(heavySolid.bounds, viewSize: CGSize(width: 1000, height: 800))
    let heavyScene = CadSceneDescription(bodies: heavy.final.bodies, camera: heavyCam, modelRevision: 99_001)
    let heavyFrameMs = time { _ = renderer.renderImage(heavyScene, width: 1000, height: 800) }
    writePNG(renderer.renderImage(heavyScene, width: 1000, height: 800), "23-stress-plate.png")
    print("  its frame at 1000×800 with read-back: \(String(format: "%.1f", heavyFrameMs)) ms")

    model.closeDocument()
    model.refreshGallery()
    check(model.galleryItems.count == 3, "gallery lists all three projects")
    snapshotView(ForgeRootView(model: model), size: CGSize(width: 1100, height: 700), name: "30-gallery.png")

    model.open(url)
    check(model.document?.name == "Bracket", "reopening from the gallery works")
    if let live = model.document { liveViewCheck(model, live) }
    model.closeDocument()

    try cloudCheck()
}

/// Builds the workspace with the real Metal view inside a window that is never shown, and asks that view to draw.
@MainActor
func liveViewCheck(_ model: ForgeAppModel, _ doc: CadDocument) {
    let host = NSHostingView(rootView: ForgeWorkspaceView(model: model, document: doc).frame(width: 1200, height: 800))
    host.sizingOptions = []
    host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    func find(_ view: NSView) -> MTKView? {
        if let m = view as? MTKView { return m }
        for sub in view.subviews { if let m = find(sub) { return m } }
        return nil
    }
    guard let metal = find(host) else {
        check(false, "the live workspace contains a Metal view")
        window.contentView = nil
        return
    }
    check(metal.bounds.width > 100 && metal.bounds.height > 100, "the live Metal view gets a real size")
    metal.draw()
    check(metal.sampleCount == CadRenderer.sampleCount, "the live view is set up for 4× anti-aliasing and survives a draw call")
    check(!window.isVisible, "testing never put a window on screen")
    window.contentView = nil
}

/// End-to-end: Forge saves a part, the gallery folder is linked to a "cloud" (a local folder through the same
/// provider interface the real clouds use), and the package arrives intact, manifest included.
@MainActor
func cloudCheck() throws {
    let root = outDir.appendingPathComponent("cloud-check")
    try? FileManager.default.removeItem(at: root)
    let gallery = root.appendingPathComponent("Gallery"), fakeCloud = root.appendingPathComponent("FakeCloud")
    try FileManager.default.createDirectory(at: fakeCloud, withIntermediateDirectories: true)
    let manager = try UniversalSyncManager(stateDirectory: root.appendingPathComponent("SyncState"))
    let cloudFolder = LocalFolderProvider(rootURL: fakeCloud, displayName: "Test Cloud", id: "testCloud")
    // Real provider objects with an in-memory token store: they report "not configured", never touch the Keychain.
    let rest = CloudProviderCatalog.standardProviders(configuration: CloudProviderConfiguration(),
                                                      tokenStore: InMemoryTokenStore()).filter { $0.id != .iCloudDrive }
    let cloud = ForgeCloudController(manager: manager, providers: [cloudFolder] + rest)
    let model = ForgeAppModel(galleryFolder: gallery, cloud: cloud)
    model.newDocument(name: "Synced Part")
    model.document?.edit { t in
        var s = Sketch2D()
        s.addRectangle(Vec2(0, 0), Vec2(30, 20))
        let id = t.append(.sketch(SketchFeature(plane: .xy, sketch: s)))
        _ = t.append(.extrude(ExtrudeFeature(sketchID: id, extent: .blind("5mm"))))
    }
    model.saveNow()
    waitFor {
        await cloud.connect(folder: gallery, to: "testCloud", remoteFolder: "/Forge Projects")
        await manager.syncAll()
        await cloud.refresh()
    }
    let remote = fakeCloud.appendingPathComponent("Forge Projects/Synced Part.forge")
    check(FileManager.default.fileExists(atPath: remote.appendingPathComponent("manifest.json").path), "part synced to the cloud folder")
    if let copy = try? CadDocument.open(remote), let doc = model.document {
        check(copy.tree == doc.tree, "cloud copy opens with the same feature tree")
        check(near(copy.bodies[0].solid.massProperties().volume, 3000), "cloud copy recomputes the same solid")
    } else {
        check(false, "cloud copy opens")
    }
    check(cloud.providers.contains { if case .notConfigured = $0.authState { return true }; return false },
          "unconfigured providers report that they need keys")
    snapshotView(ForgeCloudSettingsView(cloud: cloud, galleryFolder: gallery) {}, size: CGSize(width: 560, height: 520), name: "31-cloud-settings.png")
    model.closeDocument()
}

/// App icon: a part rendered by Forge's own renderer on a rounded steel tile.
@MainActor
func paintIcon(to path: String) throws {
    guard let renderer = CadRenderer() else { throw FeatureError("No renderer") }
    var t = FeatureTree()
    var s = Sketch2D()
    let lines = s.addRectangle(Vec2(-30, -30), Vec2(30, 30))
    s.addCircle(center: Vec2(0, 0), radius: 13)
    let id = t.append(.sketch(SketchFeature(plane: .xy, sketch: s)))
    let e = t.append(.extrude(ExtrudeFeature(sketchID: id, extent: .blind("22mm"))))
    let refs = lines.map { EdgeRef(a: FaceTag(feature: e, role: .side, entity: $0), b: FaceTag(feature: e, role: .endCap)) }
    _ = t.append(.fillet(FilletFeature(edges: refs, radius: "5mm")))
    let bodies = t.regenerate().final.bodies
    var cam = CadCamera()
    let box = bodies[0].solid.bounds
    cam.frame(box, viewSize: CGSize(width: 1024, height: 1024))
    cam.viewHeight *= 1.1
    var settings = ViewportSettings()
    settings.showGrid = false
    settings.showSketches = false
    guard let image = renderer.renderImage(CadSceneDescription(bodies: bodies, settings: settings, camera: cam), width: 1024, height: 1024),
          let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 180, cornerHeight: 180, transform: nil))
    ctx.clip()
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    guard let out = ctx.makeImage() else { return }
    try NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
    if iconMode {
        do { try paintIcon(to: CommandLine.arguments[2]) } catch { print("icon failed: \(error)"); exit(1) }
        exit(0)
    }
    do { try run() } catch { print("✗ FAIL \(error)"); failures += 1 }
}
print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
