import AppKit

enum Chrome {
    static func jsString(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8), as: UTF8.self).dropFirst().dropLast().description
    }

    /// Chromium browsers that share Chrome's AppleScript dictionary (execute javascript) and DevTools protocol.
    static let browserIDs = ["com.google.chrome", "company.thebrowser.browser", "com.brave.browser", "com.microsoft.edgemac", "com.vivaldi.vivaldi", "com.operasoftware.opera"]
    static func isBrowser(_ a: NSRunningApplication) -> Bool { browserIDs.contains { a.bundleIdentifier?.lowercased().hasPrefix($0) == true } }

    /// The browser to drive: the one in front if it is Chromium-based (Arc, Brave, Edge...), else the first one running.
    static var app: NSRunningApplication? {
        if let f = NSWorkspace.shared.frontmostApplication, isBrowser(f) { return f }
        return NSWorkspace.shared.runningApplications.first(where: isBrowser)
    }
    static var pid: pid_t { app?.processIdentifier ?? 0 }
    static var appName: String { app?.localizedName ?? "Google Chrome" }

    static func eval(_ js: String, tab: String = "") async throws -> String {
        // a tab hint must pick exactly one tab: page titles are attacker-controlled, so a first-match guess could hit the wrong page
        if !tab.isEmpty {
            let hits = try await tabs().split(separator: "\n").filter { $0.contains(tab) }
            if hits.isEmpty { throw JinnError("no Chrome tab matches \"\(tab)\"; call chrome_tabs") }
            if hits.count > 1 { throw JinnError("\(hits.count) Chrome tabs match \"\(tab)\": \(hits.prefix(4).joined(separator: " || ")). Use a more specific url_contains") }
        }
        guard let data = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:9222/json")!).0 else {
            return try await withTimeout(15, "Chrome page script") { try viaAppleScript(js, tab) }
        }
        let tabs = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []).filter { $0["type"] as? String == "page" }
        guard let t = tabs.first(where: { tab.isEmpty || ($0["url"] as? String ?? "").contains(tab) || ($0["title"] as? String ?? "").contains(tab) }),
              let ws = (t["webSocketDebuggerUrl"] as? String).flatMap(URL.init(string:)) else { throw JinnError("no matching Chrome tab") }

        let task = URLSession.shared.webSocketTask(with: ws)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        return try await withTimeout(15, "Chrome page script") { try await roundTrip(task, js) }
    }

    static func viaAppleScript(_ js: String, _ tab: String) throws -> String {
        guard pid != 0 else { throw JinnError("no Chromium browser (Chrome, Arc, Brave, Edge) is running; open_app one first") }
        let browser = AppleScript.esc(appName)
        let want = AppleScript.esc(tab)
        do {
            return try AppleScript.run("""
            tell application "\(browser)"
              set tgt to missing value
              if "\(want)" is not "" then
                repeat with w in windows
                  repeat with t in tabs of w
                    if (URL of t contains "\(want)") or (title of t contains "\(want)") then
                      set tgt to t
                      exit repeat
                    end if
                  end repeat
                  if tgt is not missing value then exit repeat
                end repeat
                if tgt is missing value then error "no matching Chrome tab"
              else
                set tgt to active tab of front window
              end if
              return execute tgt javascript "\(AppleScript.esc(js.replacingOccurrences(of: "\n", with: " ")))"
            end tell
            """)
        } catch {
            if error.localizedDescription.contains("turned off") || error.localizedDescription.contains("Apple Events") {
                throw JinnError("\(appName) blocks scripting. Ask the user to enable it in the browser menu bar: View (or Tools) > Developer > Allow JavaScript from Apple Events, then retry. Until then use look/act, which fall back to the accessibility tree and OCR.")
            }
            throw error
        }
    }

    static let page = "JSON.stringify({title:document.title,url:location.href,text:(document.body.innerText||'').slice(0,6000)})"

    static func tabs() async throws -> String {
        if let data = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:9222/json")!).0,
           let all = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return all.filter { $0["type"] as? String == "page" }.map { "\($0["title"] ?? "") | \($0["url"] ?? "")" }.joined(separator: "\n")
        }
        return try AppleScript.run("""
        tell application "\(AppleScript.esc(appName))"
          set out to ""
          repeat with w in windows
            repeat with t in tabs of w
              set out to out & (title of t) & " | " & (URL of t) & linefeed
            end repeat
          end repeat
          return out
        end tell
        """)
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
