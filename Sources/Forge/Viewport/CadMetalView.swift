import SwiftUI
import MetalKit

/// Draws the scene with `CadRenderer`. Frames are only drawn when something changed: a CAD view sitting
/// still should cost nothing.
final class CadViewCoordinator: NSObject, MTKViewDelegate {
    let renderer: CadRenderer
    let document: CadDocument

    init(renderer: CadRenderer, document: CadDocument) {
        self.renderer = renderer
        self.document = document
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let commands = renderer.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let size = view.drawableSize
        MainActor.assumeIsolated {
            renderer.encode(document.scene, into: encoder, width: Int(size.width), height: Int(size.height))
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

/// Changes that should trigger a redraw. Reading these in `body` makes SwiftUI call `update…View` when they change.
struct CadRenderToken: Equatable {
    var revision: Int
    var camera: CadCamera
    var selection: ModelSelection
    var hoverEdge: EdgeRef?
    var hoverFace: FaceTag?
    var settings: ViewportSettings
}

private func configure(_ view: MTKView, renderer: CadRenderer) {
    view.device = renderer.device
    view.colorPixelFormat = CadRenderer.colorFormat
    view.depthStencilPixelFormat = CadRenderer.depthFormat
    view.sampleCount = CadRenderer.sampleCount
    view.clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
    view.isPaused = true
    view.enableSetNeedsDisplay = true
}

#if os(macOS)
import AppKit

/// Mac input: left button picks and draws, middle button orbits, Shift+middle pans, scrolling zooms at the
/// cursor. For mice and trackpads with no middle button, Option-drag orbits and Option+Shift-drag pans.
final class CadMetalView: MTKView {
    var controller: CadInteractionController?
    private var tracking: NSTrackingArea?
    private var navigatingWithOption = false
    private var viewPoint: (NSEvent) -> CGPoint {
        { [unowned self] e in
            let p = self.convert(e.locationInWindow, from: nil)
            return CGPoint(x: p.x, y: self.bounds.height - p.y)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with e: NSEvent) {
        let handled = MainActor.assumeIsolated { () -> Bool in
            guard let controller else { return false }
            switch e.keyCode {
            case 53: return controller.perform(.finishOrCancel)
            case 51, 117: return controller.perform(.delete)
            case 36, 76:
                guard controller.document.activeCommand != nil else { return false }
                controller.document.commitCommand()
                return true
            default:
                let modifiers = e.modifierFlags.intersection([.command, .control, .option])
                guard modifiers.isEmpty, let key = e.charactersIgnoringModifiers, let action = ForgeKeymap.action(for: key) else { return false }
                return controller.perform(action)
            }
        }
        if !handled { super.keyDown(with: e) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func layout() {
        super.layout()
        MainActor.assumeIsolated { controller?.viewSize = bounds.size }
    }

    private func navigate(_ e: NSEvent) {
        MainActor.assumeIsolated {
            if e.modifierFlags.contains(.shift) {
                controller?.pan(dx: e.deltaX, dy: e.deltaY)
            } else {
                controller?.orbit(dx: e.deltaX, dy: e.deltaY)
            }
        }
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if e.modifierFlags.contains(.option) {
            navigatingWithOption = true
            return
        }
        MainActor.assumeIsolated { controller?.primaryDown(at: viewPoint(e), extend: e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.command)) }
    }

    override func mouseDragged(with e: NSEvent) {
        if navigatingWithOption {
            navigate(e)
        } else {
            MainActor.assumeIsolated { controller?.primaryDragged(to: viewPoint(e)) }
        }
    }

    override func mouseUp(with e: NSEvent) {
        navigatingWithOption = false
        MainActor.assumeIsolated { controller?.primaryUp() }
    }

    override func otherMouseDragged(with e: NSEvent) { navigate(e) }
    override func rightMouseDragged(with e: NSEvent) { navigate(e) }

    override func mouseMoved(with e: NSEvent) {
        MainActor.assumeIsolated { controller?.hover(at: viewPoint(e)) }
    }

    override func scrollWheel(with e: NSEvent) {
        let amount = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
        MainActor.assumeIsolated { controller?.zoom(factor: exp(-amount * 0.005), at: viewPoint(e)) }
    }

    override func magnify(with e: NSEvent) {
        MainActor.assumeIsolated { controller?.zoom(factor: 1 / (1 + Double(e.magnification)), at: viewPoint(e)) }
    }
}

struct CadMetalRepresentable: NSViewRepresentable {
    let renderer: CadRenderer
    let controller: CadInteractionController
    let token: CadRenderToken

    func makeCoordinator() -> CadViewCoordinator { CadViewCoordinator(renderer: renderer, document: controller.document) }

    func makeNSView(context: Context) -> CadMetalView {
        let view = CadMetalView()
        configure(view, renderer: renderer)
        view.delegate = context.coordinator
        view.controller = controller
        controller.redraw = { [weak view] in view?.needsDisplay = true }
        return view
    }

    func updateNSView(_ view: CadMetalView, context: Context) {
        view.needsDisplay = true
    }
}
#else
import UIKit

/// iPad input: one finger orbits (or draws in sketch mode), two fingers pan, pinch zooms, Pencil hover
/// previews what a tap would pick.
final class CadMetalView: MTKView, UIGestureRecognizerDelegate {
    var controller: CadInteractionController?
    private var last = CGPoint.zero

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
        let one = UIPanGestureRecognizer(target: self, action: #selector(panOne))
        one.maximumNumberOfTouches = 1
        addGestureRecognizer(one)
        let two = UIPanGestureRecognizer(target: self, action: #selector(panTwo))
        two.minimumNumberOfTouches = 2
        two.delegate = self
        addGestureRecognizer(two)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered)))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        MainActor.assumeIsolated { controller?.viewSize = bounds.size }
    }

    @objc private func tap(_ g: UITapGestureRecognizer) {
        MainActor.assumeIsolated {
            controller?.primaryDown(at: g.location(in: self))
            controller?.primaryUp()
        }
    }

    @objc private func panOne(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        MainActor.assumeIsolated {
            let sketching = controller?.document.editingSketchID != nil
            switch g.state {
            case .began:
                last = p
                if sketching { controller?.primaryDown(at: p) }
            case .changed:
                if sketching {
                    controller?.primaryDragged(to: p)
                } else {
                    controller?.orbit(dx: p.x - last.x, dy: p.y - last.y)
                }
                last = p
            default:
                if sketching { controller?.primaryUp() }
            }
        }
    }

    @objc private func panTwo(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        MainActor.assumeIsolated { controller?.pan(dx: t.x, dy: t.y) }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        let s = g.scale
        g.scale = 1
        guard s > 0 else { return }
        MainActor.assumeIsolated { controller?.zoom(factor: 1 / s, at: g.location(in: self)) }
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        MainActor.assumeIsolated { controller?.hover(at: g.location(in: self)) }
    }
}

struct CadMetalRepresentable: UIViewRepresentable {
    let renderer: CadRenderer
    let controller: CadInteractionController
    let token: CadRenderToken

    func makeCoordinator() -> CadViewCoordinator { CadViewCoordinator(renderer: renderer, document: controller.document) }

    func makeUIView(context: Context) -> CadMetalView {
        let view = CadMetalView(frame: .zero, device: renderer.device)
        configure(view, renderer: renderer)
        view.delegate = context.coordinator
        view.controller = controller
        controller.redraw = { [weak view] in view?.setNeedsDisplay() }
        return view
    }

    func updateUIView(_ view: CadMetalView, context: Context) {
        view.setNeedsDisplay()
    }
}
#endif
