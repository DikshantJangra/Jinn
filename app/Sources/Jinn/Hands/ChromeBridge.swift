import AppKit

enum Chrome {
    static func jsString(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8), as: UTF8.self).dropFirst().dropLast().description
    }

    static let fields = "(()=>[...document.querySelectorAll('input,textarea,select,[role=radio],[role=checkbox]')].filter(e=>!['hidden','submit','button'].includes(e.type)&&e.offsetParent!==null))"
    static let label = """
    (e=>{const t=n=>(n&&n.textContent||'').trim();const lb=e.getAttribute('aria-labelledby');
    return (lb&&lb.split(' ').map(i=>t(document.getElementById(i))).join(' ').trim())||e.getAttribute('aria-label')||e.getAttribute('data-value')||(e.id&&t(document.querySelector('label[for="'+e.id+'"]')))||t(e.closest('label'))||e.placeholder||e.name||''})
    """

    static let group = "(e=>{const c=e.closest('[role=listitem],fieldset');const h=c&&c.querySelector('[role=heading],legend');return h?h.textContent.trim():''})"

    static var pid: pid_t {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier?.hasPrefix("com.google.Chrome") == true }?.processIdentifier ?? 0
    }

    static func eval(_ js: String, tab: String = "") async throws -> String {
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
        guard pid != 0 else { throw JinnError("Chrome is not running; open_app Chrome first") }
        let want = AppleScript.esc(tab)
        do {
            return try AppleScript.run("""
            tell application "Google Chrome"
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
                throw JinnError("Chrome blocks scripting. Ask the user to enable Chrome menu View > Developer > Allow JavaScript from Apple Events, then retry.")
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
        tell application "Google Chrome"
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
