import Foundation
import CoreGraphics
import simd

/// Forge's keyboard shortcuts as a plain table, shared by Mac and iPad keyboards.
public enum ForgeKeyAction: Equatable, Sendable {
    case tool(SketchTool)
    case extrude, pressPull, fillet, moveCopy, commandSearch
    case finishOrCancel, delete
}

public enum ForgeKeymap {
    public static func action(for key: String) -> ForgeKeyAction? {
        switch key.lowercased() {
        case "c": return .tool(.circle)
        case "r": return .tool(.rectangle)
        case "l": return .tool(.line)
        case "a": return .tool(.arc)
        case "d": return .tool(.dimension)
        case "e": return .extrude
        case "q": return .pressPull
        case "f": return .fillet
        case "m": return .moveCopy
        case "s": return .commandSearch
        default: return nil
        }
    }
}

/// Turns pointer events into orbiting, picking and drawing. Both the Mac view and the iPad view feed this.
@MainActor
public final class CadInteractionController {
    public let document: CadDocument
    public var viewSize = CGSize(width: 800, height: 600) {
        didSet { document.lastViewSize = viewSize }
    }

    /// Asks the view to redraw.
    public var redraw: () -> Void = {}
    /// Opens the command search (the view that owns it sets this).
    public var openCommandSearch: () -> Void = {}
    /// Called when the 3-D view is clicked, so the keyboard goes back to shortcuts after typing in a field.
    public var onPointerDown: () -> Void = {}

    public init(document: CadDocument) {
        self.document = document
    }

    private var mmPerPoint: Double { document.camera.viewHeight / Double(max(viewSize.height, 1)) }
    private var sketchTolerance: Double { 9 * mmPerPoint }

    private func sketchPoint(_ p: CGPoint) -> Vec2? {
        guard let id = document.editingSketchID, let frame = document.frameForSketch(id) else { return nil }
        return frame.local(document.camera.ray(at: p, viewSize: viewSize).origin)
    }

    // MARK: Camera

    public func orbit(dx: Double, dy: Double) {
        guard document.editingSketchID == nil else { return pan(dx: dx, dy: dy) }
        document.camera.orbit(dx: dx, dy: dy)
        redraw()
    }

    public func pan(dx: Double, dy: Double) {
        document.camera.pan(dx: dx, dy: dy, viewSize: viewSize)
        redraw()
    }

    public func zoom(factor: Double, at point: CGPoint) {
        document.camera.zoom(factor: factor, at: point, viewSize: viewSize)
        redraw()
    }

    // MARK: Pointer

    public func hover(at p: CGPoint) {
        if let s = sketchPoint(p) {
            document.editor?.pointerMoved(to: s, tolerance: sketchTolerance)
            return
        }
        let pick = CadPicker.pick(p, camera: document.camera, viewSize: viewSize, bodies: document.displayBodies)
        let wantsEdge = pick.edge != nil && !isPickingFaces
        let edge = wantsEdge ? pick.edge : nil
        let face = wantsEdge || isPickingEdges ? nil : pick.face
        if edge != document.hoverEdge || face != document.hoverFace {
            document.hoverEdge = edge
            document.hoverFace = face
            redraw()
        }
    }

    private var isPickingEdges: Bool {
        switch document.activeCommand {
        case .fillet?, .chamfer?: return true
        default: return false
        }
    }

    private var isPickingFaces: Bool {
        switch document.activeCommand {
        case .shell?, .extrude?: return true
        default: return false
        }
    }

    public func primaryDown(at p: CGPoint, extend: Bool = false) {
        onPointerDown()
        if let s = sketchPoint(p) {
            document.editor?.pointerDown(at: s, tolerance: sketchTolerance, extendSelection: extend)
            return
        }
        let pick = CadPicker.pick(p, camera: document.camera, viewSize: viewSize, bodies: document.displayBodies)
        if isPickingEdges {
            if let e = pick.edge {
                document.toggle(edge: e)
                document.updateCommandPreview()
            }
        } else if isPickingFaces {
            if let f = pick.face {
                document.toggle(face: f)
                document.updateCommandPreview()
            }
        } else if let e = pick.edge {
            if !extend { document.selection = ModelSelection() }
            document.toggle(edge: e)
        } else if let f = pick.face {
            if !extend { document.selection = ModelSelection() }
            document.toggle(face: f)
        } else if !extend {
            document.selection = ModelSelection()
        }
        redraw()
    }

    public func primaryDragged(to p: CGPoint) {
        if let s = sketchPoint(p) { document.editor?.pointerDragged(to: s, tolerance: sketchTolerance) }
    }

    public func primaryUp() {
        document.editor?.pointerUp()
    }

    // MARK: Keyboard

    public func perform(_ action: ForgeKeyAction) -> Bool {
        switch action {
        case .tool(let tool):
            if document.editingSketchID == nil {
                // Drawing tools outside a sketch start one, on a picked flat face or the XY plane.
                if let tag = document.selection.faces.first {
                    document.beginSketch(on: .face(tag))
                } else {
                    document.beginSketch(on: .xy)
                }
            }
            document.editor?.tool = tool
        case .extrude:
            document.beginExtrude()
        case .pressPull:
            document.beginPressPull()
        case .fillet:
            document.beginFillet()
        case .moveCopy:
            document.statusMessage = "Move/copy isn't built yet."
        case .commandSearch:
            openCommandSearch()
        case .finishOrCancel:
            if document.editor?.pendingDimension != nil || !(document.editor?.clicks.isEmpty ?? true) {
                document.editor?.cancel()
            } else if document.editor?.tool != .select, document.editingSketchID != nil {
                document.editor?.tool = .select
            } else if document.activeCommand != nil {
                document.cancelCommand()
            } else {
                document.selection = ModelSelection()
            }
        case .delete:
            document.editor?.deleteSelection()
        }
        redraw()
        return true
    }
}
