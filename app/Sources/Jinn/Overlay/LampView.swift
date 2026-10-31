import SwiftUI
import WebKit

let lampDir: URL = {
    if let r = Bundle.main.resourceURL?.appendingPathComponent("lamp"), FileManager.default.fileExists(atPath: r.appendingPathComponent("lamp.html").path) { return r }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/lamp")
}()

enum LampState: String { case idle, listening, thinking, speaking }

struct LampView: NSViewRepresentable {
    let state: LampState
    let build: Int
    let onTap: () -> Void

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var onTap: () -> Void = {}
        var ready = false, pending = LampState.idle, lastBuild = 0
        weak var web: WKWebView?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { DispatchQueue.main.async { self.onTap() } }
        func push(_ s: LampState) { pending = s; if ready { web?.evaluateJavaScript("window.jinn&&jinn.setState('\(s.rawValue)')") } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "jinn")
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = w
        w.navigationDelegate = context.coordinator
        w.loadFileURL(lampDir.appendingPathComponent("lamp.html"), allowingReadAccessTo: lampDir)
        return w
    }

    func updateNSView(_ w: WKWebView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.push(state)
        if build != context.coordinator.lastBuild {
            context.coordinator.lastBuild = build
            if context.coordinator.ready { w.evaluateJavaScript("window.jinn&&jinn.build()") }
        }
    }
}

extension LampView.Coordinator: WKNavigationDelegate {
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { ready = true; push(pending) }
}
