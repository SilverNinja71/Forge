import SwiftUI
import simd

private struct ForgeSnapshotModeKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True when screenshotting: the live Metal view is replaced by the same picture rendered off-screen.
    public var forgeSnapshotMode: Bool {
        get { self[ForgeSnapshotModeKey.self] }
        set { self[ForgeSnapshotModeKey.self] = newValue }
    }
}

/// Everything you can search for with the S key.
struct ForgeCommandEntry: Identifiable {
    var id: String { name }
    var name: String
    var shortcut: String
    var action: () -> Void
}

/// The main window: toolbar on top, feature browser on the left, the 3-D view in the middle, settings on the right
/// and the timeline along the bottom.
public struct ForgeWorkspaceView: View {
    @Bindable var model: ForgeAppModel
    @Bindable var document: CadDocument
    @State private var controller: CadInteractionController
    @State private var showSearch = false
    @FocusState private var keyboardFocus: Bool

    public init(model: ForgeAppModel, document: CadDocument) {
        self.model = model
        self.document = document
        _controller = State(initialValue: CadInteractionController(document: document))
    }

    public var body: some View {
        VStack(spacing: 0) {
            CadToolbar(model: model, document: document, controller: controller, showSearch: $showSearch)
            Divider()
            HStack(spacing: 0) {
                FeatureBrowser(document: document)
                    .frame(width: 236)
                Divider()
                viewport
                if document.editor != nil || document.activeCommand != nil {
                    Divider()
                    sidePanel
                        .frame(width: 268)
                }
            }
            Divider()
            TimelineBarView(document: document)
        }
        .focusable(true, interactions: .edit)
        .focusEffectDisabled()
        .focused($keyboardFocus)
        .onAppear {
            keyboardFocus = true
            controller.onPointerDown = { keyboardFocus = true }
            controller.openCommandSearch = { showSearch = true }
        }
        .onChange(of: document.editor?.pendingDimension == nil) { _, done in
            if done { keyboardFocus = true }
        }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .sheet(isPresented: $showSearch) {
            CommandSearchView(commands: commands) { showSearch = false }
        }
    }

    @ViewBuilder private var viewport: some View {
        CadViewport(document: document, controller: controller, renderer: model.renderer)
            .overlay(alignment: .bottomLeading) {
                if let message = document.statusMessage {
                    Text(message)
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                        .padding(10)
                }
            }
    }

    @ViewBuilder private var sidePanel: some View {
        if document.editor != nil {
            SketchPanel(document: document)
        } else if let command = document.activeCommand {
            CommandPanel(document: document, command: command)
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .escape {
            return controller.perform(.finishOrCancel) ? .handled : .ignored
        }
        if press.key == .delete || press.key == .deleteForward {
            return controller.perform(.delete) ? .handled : .ignored
        }
        if press.key == .return, document.activeCommand != nil {
            document.commitCommand()
            return .handled
        }
        guard press.modifiers.isEmpty || press.modifiers == .shift, let action = ForgeKeymap.action(for: press.characters) else { return .ignored }
        return controller.perform(action) ? .handled : .ignored
    }

    private var commands: [ForgeCommandEntry] {
        let c = controller, d = document
        var list: [ForgeCommandEntry] = [
            .init(name: "New Sketch on XY", shortcut: "", action: { d.beginSketch(on: .xy) }),
            .init(name: "New Sketch on XZ", shortcut: "", action: { d.beginSketch(on: .xz) }),
            .init(name: "New Sketch on YZ", shortcut: "", action: { d.beginSketch(on: .yz) }),
            .init(name: "Line", shortcut: "L", action: { _ = c.perform(.tool(.line)) }),
            .init(name: "Rectangle", shortcut: "R", action: { _ = c.perform(.tool(.rectangle)) }),
            .init(name: "Circle", shortcut: "C", action: { _ = c.perform(.tool(.circle)) }),
            .init(name: "Arc", shortcut: "A", action: { _ = c.perform(.tool(.arc)) }),
            .init(name: "Dimension", shortcut: "D", action: { _ = c.perform(.tool(.dimension)) }),
            .init(name: "Extrude", shortcut: "E", action: { d.beginExtrude() }),
            .init(name: "Press-pull a face", shortcut: "Q", action: { d.beginPressPull() }),
            .init(name: "Revolve", shortcut: "", action: { d.beginRevolve() }),
            .init(name: "Fillet", shortcut: "F", action: { d.beginFillet() }),
            .init(name: "Chamfer", shortcut: "", action: { d.beginChamfer() }),
            .init(name: "Shell", shortcut: "", action: { d.beginShell() }),
            .init(name: "Inspect", shortcut: "", action: { d.activeCommand = .inspect }),
            .init(name: "Loft through unused sketches", shortcut: "", action: { d.loftUnusedSketches() }),
            .init(name: "Sweep profile along path", shortcut: "", action: { d.sweepUnusedSketches() }),
            .init(name: "Fit view", shortcut: "", action: { d.frameAll(); c.redraw() }),
            .init(name: "Reset view", shortcut: "", action: { d.resetView(); c.redraw() }),
            .init(name: "Finish sketch", shortcut: "", action: { d.finishSketch() }),
        ]
        for mode in DisplayMode.allCases {
            list.append(.init(name: "Display: \(mode.displayName)", shortcut: "", action: { d.viewport.mode = mode; c.redraw() }))
        }
        return list
    }
}

/// The 3-D view with its overlays.
struct CadViewport: View {
    @Bindable var document: CadDocument
    let controller: CadInteractionController
    let renderer: CadRenderer?
    @Environment(\.forgeSnapshotMode) private var snapshotMode

    private var token: CadRenderToken {
        CadRenderToken(revision: document.modelRevision, camera: document.camera, selection: document.selection,
                       hoverEdge: document.hoverEdge, hoverFace: document.hoverFace, settings: document.viewport)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let renderer {
                    if snapshotMode {
                        // Screenshots: the same drawing code, rendered off-screen at 2×.
                        let scale = 2
                        if let image = renderer.renderImage(document.scene, width: Int(geo.size.width) * scale, height: Int(geo.size.height) * scale) {
                            Image(decorative: image, scale: CGFloat(scale))
                        }
                    } else {
                        CadMetalRepresentable(renderer: renderer, controller: controller, token: token)
                    }
                } else {
                    Text("This Mac's graphics card couldn't start Forge's renderer.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let editor = document.editor, let id = document.editingSketchID, let frame = document.frameForSketch(id) {
                    SketchOverlay(editor: editor, frame: frame, camera: document.camera, unitScale: document.tree.unitScale)
                    if let pending = editor.pendingDimension {
                        DimensionInputBox(document: document, suggested: pending.suggested)
                            .position(document.camera.project(frame.world(pending.at), viewSize: geo.size))
                    }
                }
                OrientationGizmo(camera: document.camera)
                    .frame(width: 70, height: 70)
                    .position(x: 48, y: geo.size.height - 48)
            }
            .onAppear {
                controller.viewSize = geo.size
                document.lastViewSize = geo.size
            }
            .onChange(of: geo.size) { _, size in
                controller.viewSize = size
                document.lastViewSize = size
            }
        }
        .clipped()
    }
}

/// Typing a dimension's value or formula, such as `d1 * 2 + 5mm`.
struct DimensionInputBox: View {
    @Bindable var document: CadDocument
    @State private var text: String
    @State private var rejected = false
    @FocusState private var focused: Bool

    init(document: CadDocument, suggested: String) {
        self.document = document
        _text = State(initialValue: suggested)
    }

    var body: some View {
        HStack(spacing: 4) {
            TextField("Value or formula", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 130)
                .focused($focused)
                .onSubmit {
                    rejected = !document.commitDimension(expression: text)
                }
            Button {
                document.editor?.pendingDimension = nil
                document.editor?.selection = SketchSelection()
            } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless)
        }
        .padding(5)
        .background(rejected ? Color.red.opacity(0.25) : Color.clear)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .onAppear { focused = true }
    }
}

struct CadToolbar: View {
    @Bindable var model: ForgeAppModel
    @Bindable var document: CadDocument
    let controller: CadInteractionController
    @Binding var showSearch: Bool

    private func tool(_ title: String, _ symbol: String, _ key: String = "", enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(title).font(.system(size: 10))
            }
            .frame(minWidth: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(key.isEmpty ? title : "\(title) (\(key))")
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.closeDocument()
            } label: { Image(systemName: "square.grid.2x2") }
            .buttonStyle(.borderless)
            .help("Back to projects")
            Text(document.name).font(.headline).lineLimit(1)
            Divider().frame(height: 28)
            if document.editor != nil {
                sketchTools
            } else {
                modelTools
            }
            Spacer(minLength: 8)
            Picker("Display", selection: $document.viewport.mode) {
                ForEach(DisplayMode.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 148)
            tool("Fit", "arrow.up.left.and.arrow.down.right") {
                document.frameAll()
                controller.redraw()
            }
            tool("Home", "cube") {
                document.resetView()
                controller.redraw()
            }
            tool("Search", "magnifyingglass", "S") { showSearch = true }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    @ViewBuilder private var modelTools: some View {
        Menu {
            Button("XY plane") { document.beginSketch(on: .xy) }
            Button("XZ plane") { document.beginSketch(on: .xz) }
            Button("YZ plane") { document.beginSketch(on: .yz) }
            Divider()
            Button("Plane above XY") { document.beginSketch(on: .offset(base: 0, distance: "20mm")) }
            Button("Plane in front of XZ") { document.beginSketch(on: .offset(base: 1, distance: "20mm")) }
            Button("Plane beside YZ") { document.beginSketch(on: .offset(base: 2, distance: "20mm")) }
            if let tag = document.selection.faces.first {
                Button("Selected face") { document.beginSketch(on: .face(tag)) }
            }
        } label: {
            VStack(spacing: 1) {
                Image(systemName: "pencil.and.ruler").font(.system(size: 15))
                Text("Sketch").font(.system(size: 10))
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        tool("Extrude", "square.stack.3d.up", "E") { document.beginExtrude() }
        tool("Revolve", "arrow.triangle.2.circlepath") { document.beginRevolve() }
        tool("Fillet", "circle.bottomhalf.filled", "F") { document.beginFillet() }
        tool("Chamfer", "triangle") { document.beginChamfer() }
        tool("Shell", "cube.transparent") { document.beginShell() }
        tool("Loft", "cone") { document.loftUnusedSketches() }
        tool("Sweep", "point.topleft.down.to.point.bottomright.curvepath") { document.sweepUnusedSketches() }
        Divider().frame(height: 28)
        tool("Inspect", "ruler") { document.activeCommand = .inspect }
        tool("Undo", "arrow.uturn.backward", enabled: document.canUndo) { document.undo() }
        tool("Redo", "arrow.uturn.forward", enabled: document.canRedo) { document.redo() }
    }

    @ViewBuilder private var sketchTools: some View {
        ForEach(SketchTool.allCases) { t in
            let key = t == .line ? "L" : t == .rectangle ? "R" : t == .circle ? "C" : t == .arc ? "A" : t == .dimension ? "D" : ""
            tool(t.displayName, t.symbol, key) { document.editor?.tool = t }
                .foregroundStyle(document.editor?.tool == t ? Color.accentColor : Color.primary)
        }
        Divider().frame(height: 28)
        Button("Finish Sketch") { document.finishSketch() }
            .buttonStyle(.borderedProminent)
    }
}

/// The history as a list, with bodies and parameters underneath.
struct FeatureBrowser: View {
    @Bindable var document: CadDocument
    @State private var newName = ""
    @State private var newValue = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Features") {
                    if document.tree.features.isEmpty {
                        Text("Start with a sketch: press L, R or C to draw on the XY plane.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(document.tree.features.enumerated()), id: \.element.id) { index, f in
                        featureRow(f, index: index)
                    }
                }
                section("Bodies") {
                    if document.bodies.isEmpty {
                        Text("None yet").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(document.bodies) { b in
                        HStack(spacing: 6) {
                            Image(systemName: "cube.fill").foregroundStyle(.secondary).font(.caption)
                            Text(b.name).font(.callout)
                            Spacer()
                            Text(String(format: "%.0f mm³", b.solid.massProperties().volume))
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
                section("Parameters") {
                    ForEach(document.tree.parameters) { p in
                        ParameterRow(document: document, parameter: p)
                    }
                    HStack(spacing: 4) {
                        TextField("name", text: $newName).frame(width: 58)
                        TextField("10mm", text: $newValue)
                        Button {
                            guard !newName.isEmpty, !newValue.isEmpty else { return }
                            document.setParameter(newName, expression: newValue)
                            newName = ""
                            newValue = ""
                        } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }
                section("Units") {
                    Picker("Units", selection: Binding(get: { document.tree.unitScale == 25.4 }, set: { document.setUnits(inches: $0) })) {
                        Text("Millimetres").tag(false)
                        Text("Inches").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
            .padding(10)
        }
        .background(.background)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func featureRow(_ f: Feature, index: Int) -> some View {
        let error = document.regeneration.errors[f.id]
        let rolledBack = (document.tree.rollback ?? Int.max) <= index
        return HStack(spacing: 6) {
            Image(systemName: error != nil ? "exclamationmark.triangle.fill" : f.symbol)
                .foregroundStyle(error != nil ? Color.red : Color.secondary)
                .frame(width: 18)
            Text(f.name).lineLimit(1).font(.callout)
                .strikethrough(f.isSuppressed)
                .foregroundStyle(f.isSuppressed || rolledBack ? .secondary : .primary)
            Spacer()
            if case .sketch = f.kind, let status = document.regeneration.final.sketchSolutions[f.id]?.status {
                Circle().fill(statusColor(status)).frame(width: 7, height: 7)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { document.editFeature(f.id) }
        .help(error ?? "Double-click to edit")
        .contextMenu {
            Button("Edit") { document.editFeature(f.id) }
            Button(f.isSuppressed ? "Unsuppress" : "Suppress") { document.setSuppressed(f.id, !f.isSuppressed) }
            Button("Roll Back to Here") { document.setRollback(index) }
            Button("Delete", role: .destructive) { document.deleteFeature(f.id) }
        }
    }

    private func statusColor(_ s: ConstraintSolver.Status) -> Color {
        switch s {
        case .underConstrained: return SketchColors.free
        case .fullyConstrained: return SketchColors.fixed
        case .overConstrained: return SketchColors.conflict
        }
    }
}

struct ParameterRow: View {
    @Bindable var document: CadDocument
    let parameter: Parameter
    @State private var text: String

    init(document: CadDocument, parameter: Parameter) {
        self.document = document
        self.parameter = parameter
        _text = State(initialValue: parameter.expression)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(parameter.name).font(.caption.monospaced()).frame(width: 58, alignment: .leading).lineLimit(1)
            TextField("value", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { document.setParameter(parameter.name, expression: text) }
                .foregroundStyle(document.regeneration.parameterErrors[parameter.name] != nil ? Color.red : Color.primary)
            Button {
                document.removeParameter(parameter.name)
            } label: { Image(systemName: "minus") }
            .buttonStyle(.borderless)
        }
        .onChange(of: parameter.expression) { _, v in text = v }
    }
}

/// The history as a strip of icons with a rollback marker: drag time backwards to see or insert earlier features.
struct TimelineBarView: View {
    @Bindable var document: CadDocument

    var body: some View {
        HStack(spacing: 4) {
            Button {
                let count = document.tree.features.count
                document.setRollback(max((document.tree.rollback ?? count) - 1, 0))
            } label: { Image(systemName: "backward.end.fill") }
            .buttonStyle(.borderless)
            .help("Step back")
            Button {
                let count = document.tree.features.count
                let next = (document.tree.rollback ?? count) + 1
                document.setRollback(next >= count ? nil : next)
            } label: { Image(systemName: "forward.end.fill") }
            .buttonStyle(.borderless)
            .help("Step forward")
            Divider().frame(height: 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(document.tree.features.enumerated()), id: \.element.id) { index, f in
                        if document.tree.rollback == index { marker }
                        chip(f, active: (document.tree.rollback ?? Int.max) > index)
                    }
                    if document.tree.rollback == nil || document.tree.rollback == document.tree.features.count { marker }
                }
            }
            Spacer()
            Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(.bar)
    }

    private var summary: String {
        let triangles = document.bodies.reduce(0) { $0 + $1.solid.triangleCount }
        return "\(document.bodies.count) bod\(document.bodies.count == 1 ? "y" : "ies") · \(triangles) triangles"
    }

    private var marker: some View {
        RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 3, height: 24)
    }

    private func chip(_ f: Feature, active: Bool) -> some View {
        let failed = document.regeneration.errors[f.id] != nil
        return Button {
            document.editFeature(f.id)
        } label: {
            Image(systemName: f.symbol)
                .font(.system(size: 12))
                .frame(width: 26, height: 24)
                .background(failed ? Color.red.opacity(0.25) : Color.secondary.opacity(active ? 0.16 : 0.05), in: RoundedRectangle(cornerRadius: 5))
                .opacity(f.isSuppressed || !active ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .help(f.name)
    }
}

/// Sketch mode's side panel: colour-coded status, the constraints available for the selection, and what's applied.
struct SketchPanel: View {
    @Bindable var document: CadDocument
    @State private var editingDimension: Int?
    @State private var editText = ""
    @State private var customGrid = ""
    @State private var offsetText: String?

    private var editor: SketchEditor? { document.editor }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                status
                if let choices = editor?.availableConstraints, !choices.isEmpty {
                    GroupBox("Constrain selection") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                            ForEach(choices) { c in
                                Button(c.name) { document.editor?.applyConstraint(named: c.name) }
                                    .controlSize(.small)
                            }
                        }
                    }
                } else {
                    Text("Select points or curves (⇧-click for several) to see which constraints apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                gridPicker
                planeOffset
                if editor?.selection.curves.isEmpty == false {
                    Button("Toggle Construction") { document.editor?.toggleConstruction() }.controlSize(.small)
                }
                constraintList
            }
            .padding(10)
        }
    }

    @ViewBuilder private var status: some View {
        if let r = editor?.result {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(color(r.status)).frame(width: 10, height: 10)
                    Text(title(r)).font(.callout.weight(.semibold)).foregroundStyle(color(r.status))
                }
                Text(detail(r)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ s: ConstraintSolver.Status) -> Color {
        switch s {
        case .underConstrained: return SketchColors.free
        case .fullyConstrained: return SketchColors.fixed
        case .overConstrained: return SketchColors.conflict
        }
    }

    private func title(_ r: ConstraintSolver.Result) -> String {
        switch r.status {
        case .underConstrained: return "Under-constrained"
        case .fullyConstrained: return "Fully constrained"
        case .overConstrained: return "Over-constrained"
        }
    }

    private func detail(_ r: ConstraintSolver.Result) -> String {
        switch r.status {
        case .underConstrained:
            return "\(r.degreesOfFreedom) degree\(r.degreesOfFreedom == 1 ? "" : "s") of freedom left: blue geometry can still move."
        case .fullyConstrained:
            return "Nothing can move. Accurate to \(String(format: "%.1e", max(r.residual, 1e-12))) mm."
        case .overConstrained:
            return "Red constraints fight or repeat each other. Delete one to fix it."
        }
    }

    private var gridPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Snap").font(.caption)
                Picker("Grid", selection: Binding(get: { editor?.grid ?? .mm(1) }, set: { document.editor?.grid = $0 })) {
                    ForEach(SketchGrid.presets, id: \.self) { Text($0.displayName).tag($0) }
                    if let g = editor?.grid, !SketchGrid.presets.contains(g) { Text(g.displayName).tag(g) }
                }
                .labelsHidden()
            }
            TextField("Custom size, such as 1/16 in", text: $customGrid)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    if let g = SketchGrid.parse(customGrid) {
                        document.editor?.grid = g
                        customGrid = ""
                    }
                }
        }
    }

    @ViewBuilder private var planeOffset: some View {
        if let id = document.editingSketchID, case .sketch(let s)? = document.tree.feature(id)?.kind, case .offset(_, let distance) = s.plane {
            HStack {
                Text("Plane offset").font(.caption)
                TextField("Distance", text: Binding(get: { offsetText ?? distance }, set: { offsetText = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit {
                        if let text = offsetText { document.setSketchPlaneOffset(id, distance: text) }
                        offsetText = nil
                    }
            }
        }
    }

    @ViewBuilder private var constraintList: some View {
        if let sketch = editor?.sketch, !sketch.constraints.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Constraints").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(sketch.constraints) { c in
                    HStack(spacing: 4) {
                        Text(c.kind.displayName).font(.caption)
                            .foregroundStyle(editor?.result.conflicting.contains(c.id) == true ? SketchColors.conflict : Color.primary)
                        Spacer()
                        if let d = c.dimension {
                            if editingDimension == c.id {
                                TextField("", text: $editText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                    .frame(width: 92)
                                    .onSubmit {
                                        if document.editor?.editDimension(c.id, expression: editText) == true { editingDimension = nil }
                                    }
                            } else {
                                Button("\(d.name) = \(d.expression)") {
                                    editText = d.expression
                                    editingDimension = c.id
                                }
                                .buttonStyle(.borderless)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            }
                        }
                        Button {
                            document.editor?.removeConstraint(c.id)
                        } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Settings for the command in progress, with a live preview in the view.
struct CommandPanel: View {
    @Bindable var document: CadDocument
    let command: ActiveCommand

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(command.title).font(.title3.weight(.semibold))
                switch command {
                case .extrude(let e, let id): extrude(e, id)
                case .revolve(let r, let id): revolve(r, id)
                case .fillet(let radius, let id): fillet(radius, id)
                case .chamfer(let input, let id): chamfer(input, id)
                case .shell(let t, let id): shell(t, id)
                case .inspect: InspectionPanel(document: document)
                }
                if let error = document.previewError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if case .inspect = command {
                        Button("Close") { document.cancelCommand() }
                    } else {
                        Button("Cancel") { document.cancelCommand() }
                        Button("OK") { document.commitCommand() }
                            .buttonStyle(.borderedProminent)
                            .disabled(document.previewError != nil)
                    }
                }
            }
            .padding(10)
        }
    }

    private func set(_ c: ActiveCommand) {
        document.activeCommand = c
        document.updateCommandPreview()
    }

    private func field(_ label: String, _ value: String, _ update: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: Binding(get: { value }, set: update))
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
        }
    }

    private var sketches: [Feature] {
        document.tree.activeFeatures.filter {
            if case .sketch = $0.kind { return true }
            return false
        }
    }

    @ViewBuilder private func extrude(_ e: ExtrudeFeature, _ id: Int?) -> some View {
        Picker("Sketch", selection: Binding(get: { e.sketchID }, set: { v in
            var c = e
            c.sketchID = v
            set(.extrude(c, editing: id))
        })) {
            ForEach(sketches) { Text($0.name).tag($0.id) }
        }
        let extentIndex: Int = {
            switch e.extent {
            case .blind: return 0
            case .symmetric: return 1
            case .throughAll: return 2
            case .toObject: return 3
            }
        }()
        Picker("Extent", selection: Binding(get: { extentIndex }, set: { v in
            var c = e
            switch v {
            case 0: c.extent = .blind(extentText(e.extent))
            case 1: c.extent = .symmetric(extentText(e.extent))
            case 2: c.extent = .throughAll
            default:
                if let f = document.selection.faces.last {
                    c.extent = .toObject(f)
                } else {
                    document.statusMessage = "Click the face to go up to, then choose “To object” again."
                    return
                }
            }
            set(.extrude(c, editing: id))
        })) {
            Text("Distance").tag(0)
            Text("Symmetric").tag(1)
            Text("Through all").tag(2)
            Text("To object").tag(3)
        }
        if extentIndex <= 1 {
            field("Distance (formulas work: d1 * 2 + 5mm)", extentText(e.extent)) { text in
                var c = e
                c.extent = extentIndex == 0 ? .blind(text) : .symmetric(text)
                set(.extrude(c, editing: id))
            }
        }
        Toggle("Flip direction", isOn: Binding(get: { e.flip }, set: { v in
            var c = e
            c.flip = v
            set(.extrude(c, editing: id))
        }))
        field("Draft angle", e.draft) { text in
            var c = e
            c.draft = text
            set(.extrude(c, editing: id))
        }
        operationPicker(e.operation) { op in
            var c = e
            c.operation = op
            set(.extrude(c, editing: id))
        }
    }

    private func extentText(_ extent: ExtrudeExtent) -> String {
        switch extent {
        case .blind(let t), .symmetric(let t): return t
        default: return "10mm"
        }
    }

    private func operationPicker(_ value: BodyOperation, _ update: @escaping (BodyOperation) -> Void) -> some View {
        Picker("Operation", selection: Binding(get: { value }, set: update)) {
            ForEach(BodyOperation.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
    }

    @ViewBuilder private func revolve(_ r: RevolveFeature, _ id: Int?) -> some View {
        Picker("Sketch", selection: Binding(get: { r.sketchID }, set: { v in
            var c = r
            c.sketchID = v
            set(.revolve(c, editing: id))
        })) {
            ForEach(sketches) { Text($0.name).tag($0.id) }
        }
        let axisLines = document.regeneration.final.solvedSketches[r.sketchID]?.curves.filter(\.isLine).map(\.id) ?? []
        Picker("Axis", selection: Binding(get: {
            switch r.axis {
            case .sketchX: return -1
            case .sketchY: return -2
            case .sketchLine(let line): return line
            }
        }, set: { v in
            var c = r
            c.axis = v == -1 ? .sketchX : (v == -2 ? .sketchY : .sketchLine(v))
            set(.revolve(c, editing: id))
        })) {
            Text("Sketch X axis").tag(-1)
            Text("Sketch Y axis").tag(-2)
            ForEach(Array(axisLines.enumerated()), id: \.element) { i, line in
                Text("Sketch line \(i + 1)").tag(line)
            }
        }
        field("Angle", r.angle) { text in
            var c = r
            c.angle = text
            set(.revolve(c, editing: id))
        }
        operationPicker(r.operation) { op in
            var c = r
            c.operation = op
            set(.revolve(c, editing: id))
        }
    }

    @ViewBuilder private func fillet(_ radius: String, _ id: Int?) -> some View {
        Text("Click the edges to round. \(document.selection.edges.count) picked.").font(.caption).foregroundStyle(.secondary)
        field("Radius", radius) { set(.fillet(radius: $0, editing: id)) }
    }

    @ViewBuilder private func chamfer(_ input: FeatureChamferInput, _ id: Int?) -> some View {
        Text("Click the edges to bevel. \(document.selection.edges.count) picked.").font(.caption).foregroundStyle(.secondary)
        Picker("Kind", selection: Binding(get: { input.mode }, set: { v in
            var c = input
            c.mode = v
            set(.chamfer(kind: c, editing: id))
        })) {
            Text("Equal").tag(FeatureChamferInput.Mode.equal)
            Text("Two distances").tag(FeatureChamferInput.Mode.twoDistance)
            Text("Distance + angle").tag(FeatureChamferInput.Mode.angleDistance)
        }
        field("Distance", input.first) { v in
            var c = input
            c.first = v
            set(.chamfer(kind: c, editing: id))
        }
        if input.mode == .twoDistance {
            field("Second distance", input.second) { v in
                var c = input
                c.second = v
                set(.chamfer(kind: c, editing: id))
            }
        }
        if input.mode == .angleDistance {
            field("Angle", input.angle) { v in
                var c = input
                c.angle = v
                set(.chamfer(kind: c, editing: id))
            }
        }
    }

    @ViewBuilder private func shell(_ t: String, _ id: Int?) -> some View {
        Text("Click the faces to open up. With none picked, the body gets a closed cavity. \(document.selection.faces.count) picked.")
            .font(.caption).foregroundStyle(.secondary)
        field("Wall thickness", t) { set(.shell(thickness: $0, editing: id)) }
    }
}

/// Measurements and analysis views.
struct InspectionPanel: View {
    @Bindable var document: CadDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(document.bodies) { b in
                let m = b.solid.massProperties()
                GroupBox(b.name) {
                    VStack(alignment: .leading, spacing: 3) {
                        row("Volume", String(format: "%.2f mm³", m.volume))
                        row("Surface area", String(format: "%.2f mm²", m.surfaceArea))
                        row("Centre of mass", String(format: "%.2f, %.2f, %.2f", m.centerOfMass.x, m.centerOfMass.y, m.centerOfMass.z))
                        if m.inertia.count == 6 {
                            row("Ixx / Iyy / Izz", String(format: "%.3g / %.3g / %.3g", m.inertia[0], m.inertia[1], m.inertia[2]))
                        }
                        let s = b.solid.bounds.size
                        row("Size", String(format: "%.2f × %.2f × %.2f", s.x, s.y, s.z))
                        row("Watertight", b.solid.isClosed ? "Yes" : "No")
                    }
                }
            }
            if document.bodies.count == 2 {
                let d = document.bodies[0].solid.minimumDistance(to: document.bodies[1].solid)
                row("Minimum distance", String(format: "%.3f mm", d.distance))
            }
            GroupBox("Section plane") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Cut the model open", isOn: $document.viewport.section.isEnabled)
                    Picker("Normal", selection: $document.viewport.section.axis) {
                        Text("X").tag(0)
                        Text("Y").tag(1)
                        Text("Z").tag(2)
                    }
                    .pickerStyle(.segmented)
                    let box = document.bodies.reduce(AABB.empty) { $0.union($1.solid.bounds) }
                    if !box.isEmpty {
                        let axis = document.viewport.section.axis
                        Slider(value: $document.viewport.section.offset, in: box.lo[axis]...max(box.hi[axis], box.lo[axis] + 0.001))
                    }
                    Toggle("Flip side", isOn: $document.viewport.section.flipped)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.monospacedDigit())
        }
    }
}

/// S: type to find any command.
struct CommandSearchView: View {
    let commands: [ForgeCommandEntry]
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [ForgeCommandEntry] {
        guard !query.isEmpty else { return commands }
        return commands.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search commands", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    if let first = matches.first {
                        first.action()
                        dismiss()
                    }
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(matches) { c in
                        Button {
                            c.action()
                            dismiss()
                        } label: {
                            HStack {
                                Text(c.name)
                                Spacer()
                                Text(c.shortcut).foregroundStyle(.secondary).font(.caption.monospaced())
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Close", action: dismiss)
            }
        }
        .padding(14)
        .frame(width: 380, height: 420)
        .onAppear { focused = true }
    }
}
