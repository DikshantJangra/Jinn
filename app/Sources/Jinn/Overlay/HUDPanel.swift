import AppKit
import Combine
import SwiftUI

final class HUDPanel: NSPanel {
    init(view: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 150, height: 150),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        contentView = view
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { HUDController.shared.hide() }
}

/// The lamp lives in the bottom-right corner (voice only: click it to talk). The button on it zooms the window to the
/// centre for typing, replies and approvals; the same button, or Esc, sends it back to the corner. Hovering does nothing.
@MainActor
final class HUDController {
    static let shared = HUDController()
    let model = HUDModel()
    private lazy var host = NSHostingView(rootView: HUDView(m: model))
    private lazy var panel = HUDPanel(view: host)
    private var obs: AnyCancellable?
    private let mini = NSSize(width: 150, height: 150)

    /// The lamp lives on the main screen: in the corner and, zoomed, in the centre.
    private var screen: NSRect { (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero }
    private var miniFrame: NSRect { NSRect(x: screen.maxX - mini.width - 16, y: screen.minY + 16, width: mini.width, height: mini.height) }
    private func centered(_ s: NSSize) -> NSRect {
        NSRect(x: screen.midX - s.width / 2, y: screen.midY - s.height / 2, width: s.width, height: s.height)
    }

    /// Resting state: just the lamp, bottom-right.
    func showMini() {
        if obs == nil { obs = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.fit() } } }
        model.expanded = false
        panel.setFrame(miniFrame, display: true)
        panel.orderFrontRegardless()
        model.buildTick += 1
    }

    /// Zoom to the centre and focus the text field.
    func show() {
        guard !model.expanded else { panel.makeKey(); model.focusTick += 1; return }
        model.expanded = true
        DispatchQueue.main.async { [self] in
            panel.setFrame(centered(host.fittingSize), display: true, animate: true)
            panel.orderFrontRegardless()
            panel.makeKey()
            model.focusTick += 1
        }
    }

    /// Esc: stop whatever is happening and go back to the corner.
    func hide() {
        if model.pending != nil { model.decide(.deny) }
        model.cancelListening(); model.speech.stop()
        guard model.expanded else { return }
        model.expanded = false
        panel.setFrame(miniFrame, display: true, animate: true)
    }
    func toggle() { model.expanded ? hide() : show() }

    /// Out of the way while Jinn drives another app's window, then back to where it was.
    func suspend() -> Bool { let was = panel.isVisible; panel.orderOut(nil); return was }
    func resume(_ was: Bool) { if was { panel.orderFrontRegardless() } }

    /// Reply text grew or shrank: stay centred.
    private func fit() {
        guard model.expanded, panel.isVisible else { return }
        let target = centered(host.fittingSize), f = panel.frame
        guard abs(f.height - target.height) > 1 || abs(f.width - target.width) > 1 else { return }
        panel.setFrame(target, display: true)
    }
}
