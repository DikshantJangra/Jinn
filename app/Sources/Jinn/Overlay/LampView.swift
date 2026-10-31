import SwiftUI
import WebKit

/// Where the voxel lamp page lives: the app bundle, else the source tree (swift run / CI).
let lampDir: URL = {
    if let r = Bundle.main.resourceURL?.appendingPathComponent("lamp"), FileManager.default.fileExists(atPath: r.appendingPathComponent("lamp.html").path) { return r }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/lamp")
}()

enum LampState: String { case idle, listening, thinking, speaking }

/// The genie-and-lamp face of the HUD: a transparent WKWebView running the bundled three.js scene (offline).
/// Drag to rotate; a tap is reported through `onTap`.
struct LampView: NSViewRepresentable {
    let state: LampState
    let onTap: () -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onTap: () -> Void = {}
        var ready = false, pending = LampState.idle
        weak var web: WKWebView?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { DispatchQueue.main.async { self.onTap() } }
        func push(_ s: LampState) { pending = s; if ready { web?.evaluateJavaScript("window.jinn&&jinn.setState('\(s.rawValue)')") } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "jinn")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground") // transparent over the HUD material
        context.coordinator.web = w
        w.navigationDelegate = context.coordinator
        w.loadFileURL(lampDir.appendingPathComponent("lamp.html"), allowingReadAccessTo: lampDir)
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.push(state)
    }
}

extension LampView.Coordinator: WKNavigationDelegate {
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { ready = true; push(pending) }
}
