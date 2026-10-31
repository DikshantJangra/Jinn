import AppKit
import Combine
import SwiftUI

final class HUDPanel: NSPanel {
    init(view: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 80),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // a window shadow would outline the invisible box
        contentView = view
    }
    override var canBecomeKey: Bool { true }   // can type into it
    override var canBecomeMain: Bool { false } // but never steals "main app" from what you're doing
    /// Escape anywhere in the panel (not only inside the text field) closes it.
    override func cancelOperation(_ sender: Any?) { HUDController.shared.hide() }
}

@MainActor
final class HUDController {
    static let shared = HUDController()
    let model = HUDModel()
    private lazy var host = NSHostingView(rootView: HUDView(m: model))
    private lazy var panel = HUDPanel(view: host)
    private var placed = false
    private var obs: AnyCancellable?

    var visible: Bool { panel.isVisible }

    func show() {
        let fresh = !panel.isVisible
        if !placed {
            placed = true
            obs = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.fit() } }
        }
        if fresh { // centered on the active screen, lamp near the middle; replay the build-up
            let s = host.fittingSize
            let f = (NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main)?.visibleFrame ?? .zero
            panel.setFrame(NSRect(x: f.midX - s.width / 2, y: f.midY + 230 - s.height, width: s.width, height: s.height), display: true)
            model.buildTick += 1
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        model.focusTick += 1
    }

    /// Hiding with a question open counts as Deny; otherwise the agent waits forever and the HUD stays busy.
    func hide() {
        if model.pending != nil { model.decide(.deny) }
        model.cancelListening(); model.speech.stop()
        panel.orderOut(nil)
    }
    func toggle() { visible ? hide() : show() }

    /// Grow/shrink with content, keeping the top edge fixed.
    private func fit() {
        let s = host.fittingSize
        var f = panel.frame
        f.origin.y += f.height - s.height
        f.size = s
        panel.setFrame(f, display: true)
    }
}
