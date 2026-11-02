import Testing
import Foundation
import simd
@testable import ForgeCore
#if os(macOS)
import AppKit
#endif

/// The whole file format and the editor's drawing logic, without a window.
@Suite("Sketch editor")
struct SketchEditorTests {
    func editor() -> SketchEditor { SketchEditor(sketch: Sketch2D()) }

    @Test func lineChainsAndJoinsItsPoints() {
        var e = editor()
        e.tool = .line
        e.pointerDown(at: Vec2(0, 0), tolerance: 0.5)
        e.pointerDown(at: Vec2(10, 0), tolerance: 0.5)
        e.pointerDown(at: Vec2(10, 10), tolerance: 0.5)
        #expect(e.sketch.curves.count == 2)
        // Shared end point: 1 fixed origin + 2 more points, not 4.
        #expect(e.sketch.points.count == 3)
        // Coming back to the start closes the loop and ends the chain.
        e.pointerDown(at: Vec2(0, 0), tolerance: 0.5)
        #expect(e.clicks.isEmpty)
        #expect(e.sketch.regions().count == 1)
    }

    @Test func nearlyLevelLinesSnapAndGetAConstraint() {
        var e = editor()
        e.tool = .line
        e.grid = .off
        e.pointerDown(at: Vec2(0, 0), tolerance: 0.5)
        e.pointerDown(at: Vec2(10, 0.2), tolerance: 0.5)
        #expect(e.sketch.constraints.contains { if case .horizontal = $0.kind { return true }; return false })
        let line = e.sketch.curves[0]
        guard case .line(let a, let b) = line.geometry else { Issue.record("not a line"); return }
        #expect(abs(e.sketch.position(a).y - e.sketch.position(b).y) < 1e-9)
    }

    @Test func gridSizesAndInches() {
        var e = editor()
        e.grid = .mm(10)
        #expect(e.snap(Vec2(14, 26), tolerance: 0.1).position == Vec2(10, 30))
        e.grid = .mm(0.1)
        let tenth = e.snap(Vec2(1.23, 4.56), tolerance: 0.01).position
        #expect(abs(tenth.x - 1.2) < 1e-9 && abs(tenth.y - 4.6) < 1e-9)
        e.grid = .inches(0.125)
        #expect(abs(e.snap(Vec2(3.2, 0), tolerance: 0.01).position.x - 3.175) < 1e-9)
    }

    @Test func pointsWinOverTheGrid() {
        var s = Sketch2D()
        let p = s.addPoint(Vec2(3.3, 3.3))
        let e = SketchEditor(sketch: s)
        #expect(e.snap(Vec2(3.4, 3.2), tolerance: 0.5).kind == .existingPoint(p))
    }

    @Test func circleAndArcTools() {
        var e = editor()
        e.tool = .circle
        e.pointerDown(at: Vec2(5, 5), tolerance: 0.2)
        e.pointerDown(at: Vec2(9, 5), tolerance: 0.2)
        #expect(e.sketch.radius(of: e.sketch.curves[0].id) == 4)
        e.tool = .arc
        e.pointerDown(at: Vec2(30, 0), tolerance: 0.2)
        e.pointerDown(at: Vec2(35, 0), tolerance: 0.2)
        e.pointerDown(at: Vec2(30, 7), tolerance: 0.2)
        let arc = e.sketch.curves.last!
        guard case .arc(let c, let a, let b) = arc.geometry else { Issue.record("not an arc"); return }
        #expect(abs(simd_length(e.sketch.position(a) - e.sketch.position(c)) - simd_length(e.sketch.position(b) - e.sketch.position(c))) < 1e-9)
    }

    @Test func dimensionToolKnowsWhatYouClicked() {
        var s = Sketch2D()
        let lines = s.addRectangle(Vec2(0, 0), Vec2(10, 10))
        s.addCircle(center: Vec2(50, 50), radius: 3)
        s.addArc(center: Vec2(80, 80), start: Vec2(85, 80), end: Vec2(80, 85))
        var e = SketchEditor(sketch: s)
        e.tool = .dimension
        e.pointerDown(at: Vec2(5, 0), tolerance: 0.5)
        guard case .distance? = e.pendingDimension?.kind else { Issue.record("line should offer its length"); return }
        // A second line makes it the gap or angle between them: here the top is parallel to the bottom.
        e.pointerDown(at: Vec2(5, 10), tolerance: 0.5)
        guard case .offset? = e.pendingDimension?.kind else { Issue.record("two parallel lines should offer their gap"); return }
        e.cancel()
        e.selection = SketchSelection()
        e.pointerDown(at: Vec2(53, 50), tolerance: 0.5)
        guard case .diameter? = e.pendingDimension?.kind else { Issue.record("circle should offer its diameter"); return }
        e.cancel()
        e.pointerDown(at: Vec2(83.53, 83.53), tolerance: 0.5)
        guard case .radius? = e.pendingDimension?.kind else { Issue.record("arc should offer its radius"); return }
        e.cancel()
        e.pointerDown(at: Vec2(0, 0), tolerance: 0.3)
        e.pointerDown(at: Vec2(10, 0), tolerance: 0.3)
        guard case .distance? = e.pendingDimension?.kind else { Issue.record("two points should offer their distance"); return }
        _ = lines
    }

    @Test func badFormulaIsRefusedAndAddsNothing() {
        var s = Sketch2D()
        s.addLine(Vec2(0, 0), Vec2(10, 0))
        var e = SketchEditor(sketch: s)
        e.tool = .dimension
        e.pointerDown(at: Vec2(5, 0), tolerance: 0.5)
        let ok1 = e.commitDimension(expression: "nonsense * 2", name: "d1")
        #expect(!ok1)
        #expect(e.sketch.constraints.isEmpty)
        let ok2 = e.commitDimension(expression: "12mm", name: "d1")
        #expect(ok2)
        #expect(e.sketch.constraints.count == 1)
    }

    @Test func dimensionsCanUseEachOther() {
        var s = Sketch2D()
        let a = s.addLine(Vec2(0, 0), Vec2(10, 0))
        let b = s.addLine(Vec2(0, 5), Vec2(10, 5))
        var e = SketchEditor(sketch: s)
        let (p, q) = s.endpoints(of: a)!, (u, v) = s.endpoints(of: b)!
        e.pendingDimension = .init(kind: .distance(p: p, q: q), suggested: "", at: .zero)
        let ok3 = e.commitDimension(expression: "20mm", name: "d1")
        #expect(ok3)
        e.pendingDimension = .init(kind: .distance(p: u, q: v), suggested: "", at: .zero)
        let ok4 = e.commitDimension(expression: "d1 * 2 + 5mm", name: "d2")
        #expect(ok4)
        #expect(abs(simd_length(e.sketch.position(u) - e.sketch.position(v)) - 45) < 1e-9)
    }

    @Test func constraintChoicesFollowTheSelection() {
        var s = Sketch2D()
        let a = s.addLine(Vec2(0, 0), Vec2(10, 1))
        let b = s.addLine(Vec2(0, 5), Vec2(10, 7))
        let c = s.addCircle(center: Vec2(20, 20), radius: 3)
        var e = SketchEditor(sketch: s)
        e.selection.curves = [a, b]
        #expect(e.availableConstraints.map(\.name).contains("Perpendicular"))
        e.applyConstraint(named: "Perpendicular")
        #expect(e.selection.isEmpty)
        #expect(e.sketch.constraints.contains { if case .perpendicular = $0.kind { return true }; return false })
        e.selection.curves = [a, c]
        #expect(e.availableConstraints.map(\.name) == ["Tangent"])
        e.selection = SketchSelection()
        e.selection.points = [s.endpoints(of: a)!.a]
        #expect(e.availableConstraints.map(\.name).contains("Fix"))
        e.applyConstraint(named: "Fix")
        e.selection.points = [s.endpoints(of: a)!.a]
        #expect(e.availableConstraints.map(\.name).contains("Unfix"))
    }

    @Test func draggingWithTheSelectTool() {
        var s = Sketch2D()
        let l = s.addLine(Vec2(0, 0), Vec2(10, 0))
        s.addConstraint(.horizontal(line: l))
        let b = s.endpoints(of: l)!.b
        var e = SketchEditor(sketch: s)
        e.pointerDown(at: Vec2(10, 0), tolerance: 0.5)
        #expect(e.selection.points == [b])
        e.pointerDragged(to: Vec2(20, 6), tolerance: 0.5)
        e.pointerUp()
        #expect(abs(e.sketch.position(b).x - 20) < 1e-9 && abs(e.sketch.position(b).y - 6) < 1e-9)
    }

    @Test func deleteCleansUpAfterItself() {
        var s = Sketch2D()
        let l = s.addLine(Vec2(0, 0), Vec2(10, 0))
        s.addConstraint(.horizontal(line: l))
        var e = SketchEditor(sketch: s)
        e.selection.curves = [l]
        e.deleteSelection()
        #expect(e.sketch.curves.isEmpty)
        #expect(e.sketch.constraints.isEmpty)
        #expect(e.sketch.points.count == 1)  // only the origin
    }
}

@MainActor
@Suite("Document")
struct DocumentTests {
    func plate(_ doc: CadDocument) {
        doc.edit { t in
            var s = Sketch2D()
            s.addRectangle(Vec2(0, 0), Vec2(40, 30))
            let id = t.append(.sketch(SketchFeature(plane: .xy, sketch: s)))
            _ = t.append(.extrude(ExtrudeFeature(sketchID: id, extent: .blind("10mm"))))
        }
    }

    @Test func undoAndRedoWalkTheHistory() {
        let doc = CadDocument()
        plate(doc)
        #expect(doc.bodies.count == 1)
        doc.undo()
        #expect(doc.bodies.isEmpty)
        doc.redo()
        #expect(doc.bodies.count == 1)
        #expect(doc.hasUnsavedChanges)
    }

    @Test func aSketchIsNotCommittedUntilFinished() {
        let doc = CadDocument()
        doc.beginSketch(on: .xy)
        doc.editor?.sketch.addRectangle(Vec2(0, 0), Vec2(10, 10))
        guard case .sketch(let before)? = doc.tree.features.first?.kind else { Issue.record("no sketch"); return }
        #expect(before.sketch.curves.isEmpty)
        doc.finishSketch()
        guard case .sketch(let after)? = doc.tree.features.first?.kind else { Issue.record("no sketch"); return }
        #expect(after.sketch.curves.count == 4)
    }

    @Test func cancellingASketchKeepsTheOldOne() {
        let doc = CadDocument()
        plate(doc)
        doc.editSketch(doc.tree.features[0].id)
        doc.editor?.sketch.addCircle(center: Vec2(20, 15), radius: 3)
        doc.cancelSketch()
        #expect(abs(doc.bodies[0].solid.massProperties().volume - 12000) < 1e-6)
    }

    @Test func dimensionNamesAreUniqueAcrossSketches() {
        let doc = CadDocument()
        doc.beginSketch(on: .xy)
        doc.editor?.sketch.addLine(Vec2(0, 0), Vec2(10, 0))
        doc.editor?.tool = .dimension
        doc.editor?.pointerDown(at: Vec2(5, 0), tolerance: 0.5)
        #expect(doc.commitDimension(expression: "12mm"))
        doc.finishSketch()
        doc.beginSketch(on: .xz)
        doc.editor?.sketch.addLine(Vec2(0, 0), Vec2(10, 0))
        doc.editor?.tool = .dimension
        doc.editor?.pointerDown(at: Vec2(5, 0), tolerance: 0.5)
        #expect(doc.commitDimension(expression: "d1 + 1mm"))
        doc.finishSketch()
        var names: [String] = []
        for f in doc.tree.features { if case .sketch(let s) = f.kind { names += s.sketch.dimensionNames } }
        #expect(names == ["d1", "d2"])
        #expect(doc.regeneration.errors.isEmpty)
    }

    @Test func loftAndSweepUseTheSketchesNotYetInASolid() {
        let doc = CadDocument()
        doc.edit { t in
            var a = Sketch2D()
            a.addRectangle(Vec2(-10, -10), Vec2(10, 10))
            _ = t.append(.sketch(SketchFeature(plane: .xy, sketch: a)))
            var b = Sketch2D()
            b.addCircle(center: .zero, radius: 5)
            _ = t.append(.sketch(SketchFeature(plane: .offset(base: 0, distance: "30mm"), sketch: b)))
        }
        #expect(doc.unusedSketchIDs.count == 2)
        doc.loftUnusedSketches()
        #expect(doc.regeneration.errors.isEmpty)
        #expect(doc.bodies.count == 1 && doc.bodies[0].solid.isClosed)
        #expect(abs(doc.bodies[0].solid.bounds.hi.z - 30) < 1e-9)
        #expect(doc.unusedSketchIDs.isEmpty)
        // Moving the plane moves the top of the loft.
        doc.setSketchPlaneOffset(doc.tree.features[1].id, distance: "45mm")
        #expect(abs(doc.bodies[0].solid.bounds.hi.z - 45) < 1e-9)
        // A second loft has nothing left to work from, and says so.
        doc.loftUnusedSketches()
        #expect(doc.statusMessage != nil)
    }

    @Test func lofttingARectangleKeepsItsCorners() throws {
        let square: [Vec3] = [Vec3(-10, -10, 0), Vec3(10, -10, 0), Vec3(10, 10, 0), Vec3(-10, 10, 0)]
        let circle: [Vec3] = (0..<48).map { i in
            let a = Double(i) / 48 * 2 * .pi
            return Vec3(cos(a) * 5, sin(a) * 5, 20)
        }
        let s = try LoftSweepOp.loft(loops: [square, circle], feature: 1)
        #expect(s.isClosed)
        for corner in square {
            #expect(s.positions.contains { simd_length($0 - corner) < 1e-9 })
        }
    }

    @Test func customGridSizes() {
        #expect(SketchGrid.parse("0.5mm") == .mm(0.5))
        #expect(SketchGrid.parse("1/16 in") == .inches(0.0625))
        #expect(SketchGrid.parse("nonsense") == nil)
        #expect(SketchGrid.parse("-1mm") == nil)
    }

    @Test func commandPreviewNeverTouchesTheTree() {
        let doc = CadDocument()
        plate(doc)
        let count = doc.tree.features.count
        doc.beginExtrude()
        #expect(doc.preview != nil)
        #expect(doc.tree.features.count == count)
        doc.cancelCommand()
        #expect(doc.preview == nil)
        #expect(doc.tree.features.count == count)
    }

    @Test func editingAFeatureReplacesItInPlace() {
        let doc = CadDocument()
        plate(doc)
        let id = doc.tree.features[1].id
        doc.editFeature(id)
        guard case .extrude(var e, let editing)? = doc.activeCommand else { Issue.record("no command"); return }
        #expect(editing == id)
        e.extent = .blind("25mm")
        doc.activeCommand = .extrude(e, editing: id)
        doc.commitCommand()
        #expect(doc.tree.features.count == 2)
        #expect(abs(doc.bodies[0].solid.bounds.size.z - 25) < 1e-9)
    }

    @Test func pressPullGrowsTheChosenFace() {
        let doc = CadDocument()
        plate(doc)
        doc.selection.faces = [FaceTag(feature: doc.tree.features[1].id, role: .endCap)]
        doc.beginPressPull()
        doc.commitCommand()
        #expect(doc.regeneration.errors.isEmpty, "\(doc.regeneration.errors)")
        #expect(doc.bodies.count == 1)
        #expect(abs(doc.bodies[0].solid.bounds.hi.z - 15) < 1e-9)
    }

    @Test func aFeatureInsertedAtTheRollbackMarkerRunsBeforeLaterOnes() {
        let doc = CadDocument()
        plate(doc)
        doc.edit { t in
            var c = Sketch2D()
            c.addCircle(center: Vec2(20, 15), radius: 4)
            let id = t.append(.sketch(SketchFeature(plane: .xy, sketch: c)))
            _ = t.append(.extrude(ExtrudeFeature(sketchID: id, extent: .throughAll, operation: .cut)))
        }
        let holed = doc.bodies[0].solid.massProperties().volume
        doc.setRollback(2)
        doc.edit { t in
            _ = t.append(.chamfer(ChamferFeature(edges: [EdgeRef(a: FaceTag(feature: 2, role: .side, entity: 5), b: FaceTag(feature: 2, role: .endCap))], kind: .equal("1mm"))))
        }
        doc.setRollback(nil)
        #expect(doc.tree.features.map(\.name) == ["Sketch 1", "Extrude 1", "Chamfer 1", "Sketch 2", "Extrude 2"])
        #expect(doc.bodies[0].solid.massProperties().volume < holed)
    }

    @Test func savedProjectsRoundTripAndOnlyChangedFilesAreRewritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("forge-test-\(UUID().uuidString).forge")
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = CadDocument(name: "Saved")
        plate(doc)
        let first = try doc.save(to: dir)
        #expect(first.last == "manifest.json")
        #expect(first.contains("model.json"))
        #expect(try doc.save(to: dir) == ["manifest.json"])
        let back = try CadDocument.open(dir)
        #expect(back.tree == doc.tree)
        doc.edit { t in t.parameters.append(Parameter(name: "x", expression: "1mm")) }
        let changed = try doc.save(to: dir)
        #expect(changed.contains("model.json"))
        #expect(!changed.contains("mesh/bodies.bin"))
        #expect(CadDocument.peek(dir)?.manifest.saveCount == 3)
    }

    @Test func aFolderThatIsntAProjectIsRefused() {
        let dir = FileManager.default.temporaryDirectory
        #expect(throws: (any Error).self) { _ = try CadDocument.open(dir) }
    }

    @Test func renderingProducesThePartNotAnEmptyPicture() throws {
        guard let renderer = CadRenderer() else { Issue.record("no Metal"); return }
        let doc = CadDocument()
        plate(doc)
        doc.frameAll()
        let image = try #require(renderer.renderImage(doc.scene, width: 320, height: 240))
        #expect(image.width == 320)
        let data = try #require(image.dataProvider?.data)
        let bytes = try #require(CFDataGetBytePtr(data))
        // The centre of the picture is the plate, not the pale background.
        let p = 120 * image.bytesPerRow + 160 * 4
        #expect(Int(bytes[p + 2]) < 215)
    }
}

#if os(macOS)
/// Sends real AppKit events into the Mac view, as the system would (it just never reaches the screen).
@MainActor
@Suite("Mac input")
struct MacInputTests {
    func setUp() -> (CadMetalView, CadDocument) {
        let doc = CadDocument()
        doc.edit { t in
            var s = Sketch2D()
            s.addRectangle(Vec2(-20, -15), Vec2(20, 15))
            let id = t.append(.sketch(SketchFeature(plane: .xy, sketch: s)))
            _ = t.append(.extrude(ExtrudeFeature(sketchID: id, extent: .blind("10mm"))))
        }
        let view = CadMetalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), device: nil)
        let controller = CadInteractionController(document: doc)
        controller.viewSize = view.bounds.size
        view.controller = controller
        return (view, doc)
    }

    func mouseEvent(_ type: CGEventType, button: CGMouseButton = .left, at p: CGPoint, flags: CGEventFlags = [], delta: CGPoint = .zero) -> NSEvent {
        let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)!
        cg.flags = flags
        cg.setDoubleValueField(.mouseEventDeltaX, value: delta.x)
        cg.setDoubleValueField(.mouseEventDeltaY, value: delta.y)
        return NSEvent(cgEvent: cg)!
    }

    @Test func middleDragOrbits() {
        let (view, doc) = setUp()
        let before = doc.camera.rotation
        view.otherMouseDragged(with: mouseEvent(.otherMouseDragged, button: .center, at: CGPoint(x: 100, y: 100), delta: CGPoint(x: 30, y: 0)))
        let turned = doc.camera.rotation.vector != before.vector
        #expect(turned)
        #expect(doc.camera.target == .zero)
    }

    @Test func shiftMiddleDragPans() {
        let (view, doc) = setUp()
        let before = doc.camera.rotation
        view.otherMouseDragged(with: mouseEvent(.otherMouseDragged, button: .center, at: CGPoint(x: 100, y: 100), flags: .maskShift, delta: CGPoint(x: 30, y: 10)))
        let turned = doc.camera.rotation.vector != before.vector
        #expect(!turned)
        #expect(doc.camera.target != .zero)
    }

    @Test func scrollZoomsIn() {
        let (view, doc) = setUp()
        let height = doc.camera.viewHeight
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0)!
        view.scrollWheel(with: NSEvent(cgEvent: cg)!)
        #expect(doc.camera.viewHeight < height)
    }

    @Test func clickingAFaceSelectsIt() {
        let (view, doc) = setUp()
        doc.camera.target = Vec3(0, 0, 10)
        // A mouse event without a window measures from the view's bottom-left, in the view's own coordinates.
        let screen = doc.camera.project(Vec3(0, 0, 10), viewSize: view.bounds.size)
        let p = CGPoint(x: screen.x, y: view.bounds.height - screen.y)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: down)
        #expect(doc.selection.faces == [FaceTag(feature: 2, role: .endCap)])
    }

    func key(_ characters: String, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    @Test func keysReachTheShortcutTable() {
        let (view, doc) = setUp()
        view.keyDown(with: key("e"))
        guard case .extrude? = doc.activeCommand else { Issue.record("E should open extrude"); return }
        view.keyDown(with: key("\u{1b}", code: 53))
        #expect(doc.activeCommand == nil)
        view.keyDown(with: key("l"))
        #expect(doc.editor?.tool == .line)
        view.keyDown(with: key("c"))
        #expect(doc.editor?.tool == .circle)
        // Escape steps back to the select tool, leaving sketch mode to the Finish button.
        view.keyDown(with: key("\u{1b}", code: 53))
        #expect(doc.editor?.tool == .select)
        doc.finishSketch()
        var opened = false
        view.controller?.openCommandSearch = { opened = true }
        view.keyDown(with: key("s"))
        #expect(opened)
    }

    @Test func clickingTheViewHandsTheKeyboardBack() {
        let (view, _) = setUp()
        var told = false
        view.controller?.onPointerDown = { told = true }
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: down)
        #expect(told)
    }

    @Test func optionDragOrbitsForMiceWithoutAMiddleButton() {
        let (view, doc) = setUp()
        let before = doc.camera.rotation
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 50, y: 50), modifierFlags: .option, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: down)
        #expect(doc.selection.isEmpty)
        view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: CGPoint(x: 60, y: 60), delta: CGPoint(x: 20, y: 5)))
        let turned = doc.camera.rotation.vector != before.vector
        #expect(turned)
    }
}
#endif
