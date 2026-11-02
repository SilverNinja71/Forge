import Foundation
import Observation
import CoreGraphics
import simd

/// What the viewport draws faces and edges as.
public enum DisplayMode: String, CaseIterable, Identifiable, Sendable {
    case shaded, shadedEdges, hiddenLine, wireframe, zebra, draftAnalysis

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .shaded: return "Shaded"
        case .shadedEdges: return "Shaded with edges"
        case .hiddenLine: return "Hidden line"
        case .wireframe: return "Wireframe"
        case .zebra: return "Zebra analysis"
        case .draftAnalysis: return "Draft analysis"
        }
    }
}

/// A plane that slices the model open for inspection: everything on its positive side is hidden.
public struct SectionPlane: Equatable, Sendable {
    public var isEnabled = false
    public var axis = 0
    public var offset = 0.0
    public var flipped = false

    public init() {}

    public var normal: Vec3 {
        var n = Vec3.zero
        n[axis] = flipped ? -1 : 1
        return n
    }

    public var plane: Plane3 { Plane3(normal: normal, d: (flipped ? -1 : 1) * offset) }
}

public struct ViewportSettings: Equatable, Sendable {
    public var mode: DisplayMode = .shadedEdges
    public var section = SectionPlane()
    public var showGrid = true
    public var showSketches = true
    /// For draft analysis.
    public var pullDirection = Vec3(0, 0, 1)
    public var requiredDraft = 1.0 * Double.pi / 180
    public init() {}
}

public struct ModelSelection: Equatable, Sendable {
    public var faces: [FaceTag] = []
    public var edges: [EdgeRef] = []
    public var isEmpty: Bool { faces.isEmpty && edges.isEmpty }
    public init() {}
}

/// A feature being set up in the side panel.
public enum ActiveCommand: Equatable, Sendable {
    case extrude(ExtrudeFeature, editing: Int?)
    case revolve(RevolveFeature, editing: Int?)
    case fillet(radius: String, editing: Int?)
    case chamfer(kind: FeatureChamferInput, editing: Int?)
    case shell(thickness: String, editing: Int?)
    case inspect

    public var title: String {
        switch self {
        case .extrude: return "Extrude"
        case .revolve: return "Revolve"
        case .fillet: return "Fillet"
        case .chamfer: return "Chamfer"
        case .shell: return "Shell"
        case .inspect: return "Inspect"
        }
    }
}

public struct FeatureChamferInput: Equatable, Sendable {
    public enum Mode: String, CaseIterable, Sendable {
        case equal, twoDistance, angleDistance
    }

    public var mode: Mode = .equal
    public var first = "1mm"
    public var second = "1mm"
    public var angle = "45deg"
    public init() {}
}

/// One open `.forge` part: its history, the model it computes, selection, undo and view.
@MainActor
@Observable
public final class CadDocument {
    public private(set) var tree: FeatureTree
    public private(set) var regeneration: FeatureTree.Regeneration
    public var name: String
    public var fileURL: URL?
    public var hasUnsavedChanges = false
    public var created = Date()
    public var saveCount = 0
    /// Bumped whenever the visible model changes, so the renderer knows to rebuild its buffers.
    public private(set) var modelRevision = 0

    public var selection = ModelSelection()
    public var viewport = ViewportSettings()
    public var camera = CadCamera()
    public var activeCommand: ActiveCommand?
    public var hoverEdge: EdgeRef?
    public var hoverFace: FaceTag?
    public var statusMessage: String?
    /// What a command would produce, shown live while its settings are being changed.
    public private(set) var preview: FeatureTree.Regeneration?
    public private(set) var previewError: String?
    /// The viewport's size in points, kept for commands such as "fit to view".
    @ObservationIgnored public var lastViewSize = CGSize(width: 800, height: 600)

    /// The sketch being edited, if any. Its feature stays in the tree; this is the live working copy.
    public private(set) var editingSketchID: Int?
    public var editor: SketchEditor? {
        didSet { sketchRevision &+= 1 }
    }
    public private(set) var sketchRevision = 0
    /// The view to return to when sketch mode ends.
    @ObservationIgnored private var cameraBeforeSketch: CadCamera?

    @ObservationIgnored private var undoStack: [FeatureTree] = []
    @ObservationIgnored private var redoStack: [FeatureTree] = []
    /// Called after every edit (autosave hooks in here).
    @ObservationIgnored public var onChange: (() -> Void)?

    public init(name: String = "Untitled", tree: FeatureTree = FeatureTree()) {
        self.name = name
        self.tree = tree
        regeneration = tree.regenerate()
    }

    public var bodies: [Body] { regeneration.final.bodies }

    /// What the viewport shows: a command's live preview, or (in sketch mode) the model as of that sketch.
    public var displayBodies: [Body] {
        if let preview { return preview.final.bodies }
        if let id = editingSketchID, let i = tree.activeFeatures.firstIndex(where: { $0.id == id }) {
            return i > 0 && i - 1 < regeneration.states.count ? regeneration.states[i - 1].bodies : []
        }
        return bodies
    }

    public var scene: CadSceneDescription {
        CadSceneDescription(bodies: displayBodies, sketches: visibleSketches, selection: selection, hoverEdge: hoverEdge, hoverFace: hoverFace,
                            settings: viewport, camera: camera, showDatumPlanes: bodies.isEmpty && editingSketchID == nil && tree.features.isEmpty,
                            modelRevision: modelRevision)
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Editing the tree

    /// Every change to the model goes through here: it records undo, finds what changed and re-runs from there.
    public func edit(_ body: (inout FeatureTree) -> Void) {
        let before = tree
        body(&tree)
        guard tree != before else { return }
        undoStack.append(before)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        regenerate(from: before)
        hasUnsavedChanges = true
        onChange?()
    }

    private func regenerate(from before: FeatureTree) {
        var first = 0
        if tree.parameters == before.parameters, tree.unitScale == before.unitScale {
            let a = tree.activeFeatures, b = before.activeFeatures
            let shared = min(a.count, b.count)
            first = shared
            for i in 0..<shared where a[i] != b[i] {
                first = i
                break
            }
        }
        regeneration = tree.regenerate(reusing: regeneration, firstChanged: first)
        modelRevision &+= 1
        pruneSelection()
    }

    private func pruneSelection() {
        let solids = bodies.map(\.solid)
        selection.faces.removeAll { tag in !solids.contains { $0.tags.contains(tag) } }
        selection.edges.removeAll { ref in !solids.contains { !$0.edgeIndices(for: ref).isEmpty } }
    }

    public func undo() {
        guard editingSketchID == nil, let previous = undoStack.popLast() else { return }
        let current = tree
        redoStack.append(current)
        tree = previous
        regenerate(from: current)
        hasUnsavedChanges = true
        onChange?()
    }

    public func redo() {
        guard editingSketchID == nil, let next = redoStack.popLast() else { return }
        let current = tree
        undoStack.append(current)
        tree = next
        regenerate(from: current)
        hasUnsavedChanges = true
        onChange?()
    }

    public func deleteFeature(_ id: Int) {
        edit { t in
            t.features.removeAll { $0.id == id }
            if let r = t.rollback { t.rollback = min(r, t.features.count) }
        }
    }

    public func setSuppressed(_ id: Int, _ value: Bool) {
        edit { t in
            if let i = t.features.firstIndex(where: { $0.id == id }) { t.features[i].isSuppressed = value }
        }
    }

    /// Moves the rollback marker: index = how many features stay active. Past the end means "show everything".
    public func setRollback(_ index: Int?) {
        edit { t in
            if let index, index < t.features.count { t.rollback = max(0, index) } else { t.rollback = nil }
        }
    }

    public func setParameter(_ name: String, expression: String) {
        edit { t in
            if let i = t.parameters.firstIndex(where: { $0.name == name }) {
                t.parameters[i].expression = expression
            } else {
                t.parameters.append(Parameter(name: name, expression: expression))
            }
        }
    }

    public func removeParameter(_ name: String) {
        edit { t in t.parameters.removeAll { $0.name == name } }
    }

    public func setUnits(inches: Bool) {
        edit { t in t.unitScale = inches ? 25.4 : 1 }
    }

    // MARK: Sketch mode

    /// Starts a new sketch on a plane and enters sketch mode.
    public func beginSketch(on plane: SketchPlaneRef) {
        var id = 0
        edit { t in id = t.append(.sketch(SketchFeature(plane: plane))) }
        editSketch(id)
    }

    /// Enters sketch mode on an existing sketch. Later features stand down until the sketch is finished.
    public func editSketch(_ id: Int) {
        guard case .sketch(let feature)? = tree.feature(id)?.kind else { return }
        activeCommand = nil
        preview = nil
        selection = ModelSelection()
        editingSketchID = id
        modelRevision &+= 1
        let values = valuesAvailable(to: id)
        editor = SketchEditor(sketch: feature.sketch, values: values, unitScale: tree.unitScale)
        cameraBeforeSketch = camera
        if let frame = frameForSketch(id) { camera.look(along: frame) }
    }

    private func restoreCameraAfterSketch() {
        // Keep the zoom the user reached in the sketch, but return to the 3-D angle they came from.
        if let before = cameraBeforeSketch { camera.rotation = before.rotation }
        cameraBeforeSketch = nil
    }

    private func valuesAvailable(to id: Int) -> [String: Quantity] {
        guard let index = tree.features.firstIndex(where: { $0.id == id }) else { return [:] }
        if index > 0, index - 1 < regeneration.states.count {
            return regeneration.states[index - 1].values
        }
        return ParameterSolver.evaluate(tree.parameters.map { ($0.name, $0.expression) }, defaultLength: tree.unitScale).values
    }

    public func frameForSketch(_ id: Int) -> Frame3? {
        if let f = regeneration.final.sketchFrames[id] { return f }
        // A sketch beyond the rollback marker hasn't run yet: datum planes are still known.
        if case .sketch(let s)? = tree.feature(id)?.kind {
            switch s.plane {
            case .xy: return .xy
            case .xz: return .xz
            case .yz: return .yz
            default: return nil
            }
        }
        return nil
    }

    /// Finishes sketch mode, stores the sketch and re-runs everything after it.
    public func finishSketch() {
        guard let id = editingSketchID, let current = editor else { return }
        editingSketchID = nil
        editor = nil
        restoreCameraAfterSketch()
        edit { t in
            if let i = t.features.firstIndex(where: { $0.id == id }), case .sketch(var s) = t.features[i].kind {
                s.sketch = current.sketch
                t.features[i].kind = .sketch(s)
            }
        }
    }

    /// Leaves sketch mode without keeping this editing session's changes.
    public func cancelSketch() {
        editingSketchID = nil
        editor = nil
        restoreCameraAfterSketch()
        modelRevision &+= 1
    }

    /// Adds a dimension the user typed, naming it uniquely across the model.
    @discardableResult
    public func commitDimension(expression: String) -> Bool {
        guard editor?.pendingDimension != nil else { return false }
        // Names are taken from the tree so they stay unique across every sketch.
        var t = tree
        var name = t.takeDimensionName()
        while editor?.sketch.dimensionNames.contains(name) == true { name = t.takeDimensionName() }
        guard editor?.commitDimension(expression: expression, name: name) == true else { return false }
        tree.nextDimensionNumber = t.nextDimensionNumber
        return true
    }

    // MARK: Commands

    /// The sketch the next feature should use: the selected one, or the newest.
    public var defaultSketchID: Int? {
        tree.activeFeatures.last { f in
            if case .sketch = f.kind { return true }
            return false
        }?.id
    }

    public func beginExtrude() {
        guard editingSketchID == nil else { return }
        guard let id = defaultSketchID else {
            statusMessage = "Draw a sketch first, then extrude it."
            return
        }
        activeCommand = .extrude(ExtrudeFeature(sketchID: id, extent: .blind("10mm"), operation: bodies.isEmpty ? .newBody : .join), editing: nil)
        updateCommandPreview()
    }

    public func beginRevolve() {
        guard editingSketchID == nil, let id = defaultSketchID else {
            statusMessage = "Draw a sketch first, then revolve it."
            return
        }
        activeCommand = .revolve(RevolveFeature(sketchID: id, axis: .sketchY, operation: bodies.isEmpty ? .newBody : .join), editing: nil)
        updateCommandPreview()
    }

    public func beginFillet() {
        guard editingSketchID == nil else { return }
        activeCommand = .fillet(radius: "2mm", editing: nil)
        selection.faces = []
        updateCommandPreview()
    }

    public func beginChamfer() {
        guard editingSketchID == nil else { return }
        activeCommand = .chamfer(kind: FeatureChamferInput(), editing: nil)
        selection.faces = []
        updateCommandPreview()
    }

    public func beginShell() {
        guard editingSketchID == nil else { return }
        activeCommand = .shell(thickness: "2mm", editing: nil)
        selection = ModelSelection()
    }

    /// The two newest sketches no solid uses yet, oldest first: what Loft and Sweep work from.
    public var unusedSketchIDs: [Int] {
        let visible = Set(visibleSketches.map(\.id))
        return tree.activeFeatures.filter { visible.contains($0.id) }.map(\.id)
    }

    /// Lofts through every sketch not yet used by a solid.
    public func loftUnusedSketches() {
        let ids = unusedSketchIDs
        guard ids.count >= 2 else {
            statusMessage = "Draw at least two closed sketches on different planes, then loft between them."
            return
        }
        addFeature(.loft(LoftFeature(sketchIDs: ids, operation: bodies.isEmpty ? .newBody : .join)))
    }

    /// Sweeps the older of the last two unused sketches along the newer one.
    public func sweepUnusedSketches() {
        let ids = unusedSketchIDs.suffix(2)
        guard ids.count == 2, let profile = ids.first, let path = ids.last else {
            statusMessage = "Draw a closed profile, then a path sketch, then sweep."
            return
        }
        addFeature(.sweep(SweepFeature(profileSketchID: profile, pathSketchID: path, operation: bodies.isEmpty ? .newBody : .join)))
    }

    private func addFeature(_ kind: Feature.Kind) {
        var id = 0
        edit { t in id = t.append(kind) }
        statusMessage = regeneration.errors[id]
    }

    /// Moves an offset sketch plane. A formula works here too.
    public func setSketchPlaneOffset(_ id: Int, distance: String) {
        edit { t in
            if let i = t.features.firstIndex(where: { $0.id == id }), case .sketch(var s) = t.features[i].kind, case .offset(let base, _) = s.plane {
                s.plane = .offset(base: base, distance: distance)
                t.features[i].kind = .sketch(s)
            }
        }
    }

    /// Opens a feature's settings for editing.
    public func editFeature(_ id: Int) {
        guard let f = tree.feature(id) else { return }
        switch f.kind {
        case .sketch: editSketch(id)
        case .extrude(let e): activeCommand = .extrude(e, editing: id)
        case .revolve(let r): activeCommand = .revolve(r, editing: id)
        case .fillet(let x):
            selection.edges = x.edges
            activeCommand = .fillet(radius: x.radius, editing: id)
        case .chamfer(let x):
            selection.edges = x.edges
            var input = FeatureChamferInput()
            switch x.kind {
            case .equal(let d): input.first = d
            case .twoDistance(let a, let b):
                input.mode = .twoDistance
                input.first = a
                input.second = b
            case .angleDistance(let d, let a):
                input.mode = .angleDistance
                input.first = d
                input.angle = a
            }
            activeCommand = .chamfer(kind: input, editing: id)
        case .shell(let x):
            selection.faces = x.openFaces
            activeCommand = .shell(thickness: x.thickness, editing: id)
        case .loft, .sweep:
            statusMessage = "\(f.name) can be suppressed or deleted; its settings can't be edited yet."
        }
        updateCommandPreview()
    }

    /// The feature a command stands for right now. Nil when it still needs input (such as picking edges).
    private func featureKind(for command: ActiveCommand) -> (kind: Feature.Kind, editing: Int?)? {
        switch command {
        case .extrude(let e, let id):
            return (.extrude(e), id)
        case .revolve(let r, let id):
            return (.revolve(r), id)
        case .fillet(let radius, let id):
            guard !selection.edges.isEmpty else { return nil }
            return (.fillet(FilletFeature(edges: selection.edges, radius: radius)), id)
        case .chamfer(let input, let id):
            guard !selection.edges.isEmpty else { return nil }
            let k: ChamferFeature.Kind
            switch input.mode {
            case .equal: k = .equal(input.first)
            case .twoDistance: k = .twoDistance(input.first, input.second)
            case .angleDistance: k = .angleDistance(distance: input.first, angle: input.angle)
            }
            return (.chamfer(ChamferFeature(edges: selection.edges, kind: k)), id)
        case .shell(let t, let id):
            return (.shell(ShellFeature(openFaces: selection.faces, thickness: t)), id)
        case .inspect:
            return nil
        }
    }

    /// Recomputes the live preview after a command's settings or its picked edges changed.
    public func updateCommandPreview() {
        guard let command = activeCommand, let (kind, editing) = featureKind(for: command) else {
            if preview != nil { modelRevision &+= 1 }
            preview = nil
            previewError = nil
            return
        }
        var t = tree
        let id: Int
        let first: Int
        if let editing, let i = t.features.firstIndex(where: { $0.id == editing }) {
            t.features[i].kind = kind
            id = editing
            first = i
        } else {
            id = t.append(kind)
            first = t.features.firstIndex { $0.id == id } ?? 0
        }
        let result = t.regenerate(reusing: regeneration, firstChanged: first)
        preview = result
        previewError = result.errors[id]
        modelRevision &+= 1
    }

    /// Confirms the side panel: adds the new feature or updates the one being edited.
    public func commitCommand() {
        guard let command = activeCommand else { return }
        if case .inspect = command {
            activeCommand = nil
            return
        }
        guard let (kind, editing) = featureKind(for: command) else {
            statusMessage = "Click the edges to use first."
            return
        }
        var newID = editing ?? 0
        preview = nil
        previewError = nil
        edit { t in
            if let editing, let i = t.features.firstIndex(where: { $0.id == editing }) {
                t.features[i].kind = kind
            } else {
                newID = t.append(kind)
            }
        }
        modelRevision &+= 1
        activeCommand = nil
        selection = ModelSelection()
        statusMessage = regeneration.errors[newID]
    }

    public func cancelCommand() {
        activeCommand = nil
        preview = nil
        previewError = nil
        modelRevision &+= 1
    }

    /// Q: pull a flat face outward. Makes a sketch of the face's outline, then an extrude from it.
    public func beginPressPull() {
        guard editingSketchID == nil else { return }
        guard let tag = selection.faces.first,
              let face = bodies.lazy.compactMap({ $0.solid.faces(tagged: tag).first }).first,
              let solid = bodies.first(where: { !$0.solid.faces(tagged: tag).isEmpty })?.solid else {
            statusMessage = "Click a flat face first, then press Q."
            return
        }
        guard solid.faces(tagged: tag).count == 1, let outline = face.loops.first else {
            statusMessage = "Press-pull works on flat faces."
            return
        }
        let frame = Frame3.on(plane: face.plane, near: .zero)
        var sketch = Sketch2D()
        let points = face.verts[outline].map { sketch.addPoint(frame.local(solid.positions[Int($0)])) }
        for i in points.indices { sketch.addLine(from: points[i], to: points[(i + 1) % points.count]) }
        var id = 0
        edit { t in id = t.append(.sketch(SketchFeature(plane: .face(tag), sketch: sketch))) }
        selection = ModelSelection()
        activeCommand = .extrude(ExtrudeFeature(sketchID: id, extent: .blind("5mm"), operation: .join), editing: nil)
        updateCommandPreview()
    }

    public func frameAll() {
        let box = displayBodies.reduce(AABB.empty) { $0.union($1.solid.bounds) }
        camera.frame(box.isEmpty ? AABB(lo: Vec3(repeating: -40), hi: Vec3(repeating: 40)) : box, viewSize: lastViewSize)
    }

    public func resetView() {
        camera.rotation = CadCamera.isoRotation
        frameAll()
    }

    // MARK: Selecting

    public func toggle(edge: EdgeRef) {
        if let i = selection.edges.firstIndex(where: { $0.joins(edge.a, edge.b) }) {
            selection.edges.remove(at: i)
        } else {
            selection.edges.append(edge)
        }
    }

    public func toggle(face: FaceTag) {
        if let i = selection.faces.firstIndex(of: face) {
            selection.faces.remove(at: i)
        } else {
            selection.faces.append(face)
        }
    }

    /// Sketches to draw outside sketch mode. Once a feature has used a sketch its curves stop showing, just like
    /// other CAD apps: the solid's own edges say the same thing.
    public var visibleSketches: [(frame: Frame3, sketch: Sketch2D, id: Int)] {
        var used = Set<Int>()
        for f in tree.features {
            switch f.kind {
            case .extrude(let e): used.insert(e.sketchID)
            case .revolve(let r): used.insert(r.sketchID)
            case .loft(let l): used.formUnion(l.sketchIDs)
            case .sweep(let s): used.formUnion([s.profileSketchID, s.pathSketchID])
            default: break
            }
        }
        return tree.activeFeatures.compactMap { f in
            guard case .sketch = f.kind, !f.isSuppressed, f.id != editingSketchID, !used.contains(f.id),
                  let frame = regeneration.final.sketchFrames[f.id], let solved = regeneration.final.solvedSketches[f.id] else { return nil }
            return (frame, solved, f.id)
        }
    }
}
