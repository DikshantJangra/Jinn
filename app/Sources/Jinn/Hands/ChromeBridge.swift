import AppKit

/// Drives Chrome through the DevTools port, so pages are read and filled without taking focus.
/// Chrome must run with --remote-debugging-port=9222 and a non-default --user-data-dir.
enum Chrome {
    static func jsString(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8), as: UTF8.self).dropFirst().dropLast().description
    }

    /// JS: visible form controls on the page.
    static let fields = "(()=>[...document.querySelectorAll('input,textarea,select,[role=radio],[role=checkbox]')].filter(e=>!['hidden','submit','button'].includes(e.type)&&e.offsetParent!==null))"
    /// JS: best human label for a control (aria-labelledby, aria-label, <label for>, wrapping label, placeholder, name).
    static let label = """
    (e=>{const t=n=>(n&&n.textContent||'').trim();const lb=e.getAttribute('aria-labelledby');
    return (lb&&lb.split(' ').map(i=>t(document.getElementById(i))).join(' ').trim())||e.getAttribute('aria-label')||(e.id&&t(document.querySelector('label[for="'+e.id+'"]')))||t(e.closest('label'))||e.placeholder||e.name||''})
    """

    static var pid: pid_t {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.hasPrefix("com.google.Chrome") == true }?.processIdentifier ?? 0
    }

    static func eval(_ js: String, tab: String = "") async throws -> String {
        let data: Data
        do { (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:9222/json")!) }
        catch { throw JinnError("Chrome debug port closed. Launch: open -na 'Google Chrome' --args --remote-debugging-port=9222 --user-data-dir=$HOME/.jinn-chrome") }
        let tabs = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []).filter { $0["type"] as? String == "page" }
        guard let t = tabs.first(where: { tab.isEmpty || ($0["url"] as? String ?? "").contains(tab) }),
              let ws = (t["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else { throw JinnError("no matching Chrome tab") }

        let task = URLSession.shared.webSocketTask(with: ws)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        // a hung page or a dialog blocking the renderer must not stall the agent forever
        return try await withTimeout(15, "Chrome page script") { try await roundTrip(task, js) }
    }

    private static func roundTrip(_ task: URLSessionWebSocketTask, _ js: String) async throws -> String {
        let req: [String: Any] = ["id": 1, "method": "Runtime.evaluate", "params": ["expression": js, "returnByValue": true]]
        try await task.send(.string(String(decoding: try JSONSerialization.data(withJSONObject: req), as: UTF8.self)))
        while true {
            guard case .string(let s) = try await task.receive(), let m = try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any], m["id"] as? Int == 1 else { continue }
            let res = (m["result"] as? [String: Any]) ?? [:]
            if let ex = res["exceptionDetails"] as? [String: Any] { throw JinnError("page script error: \((ex["exception"] as? [String: Any])?["description"] ?? ex["text"] ?? "?")") }
            return ((res["result"] as? [String: Any])?["value"]).map { "\($0)" } ?? ""
        }
    }
}
