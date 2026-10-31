import AppKit
import ApplicationServices

/// Search-the-chat shortcut per messaging app (bundle id prefix); default cmd+f.
private let chatSearchKey: [String: String] = ["com.tinyspeck.slackmacgap": "cmd+k", "com.hnc.discord": "cmd+k"]

let controlTools: [Tool] = [
    Tool(name: "quit_app", description: "Quit a running Mac app (like Cmd+Q). Unsaved work may prompt in the app.",
         params: ["app": "Running app name"], risk: .app("app")) { a in
        let app = try Apps.resolve(try a.str("app"))
        guard app.terminate() else { throw JinnError("\(app.localizedName ?? "app") refused to quit") }
        return "Asked \(app.localizedName ?? "app") to quit."
    },
    Tool(name: "close_window", description: "Close the front window of an app (its red close button), without focusing it. The app keeps running.",
         params: ["app": "Running app name"], risk: .app("app")) { a in
        let app = try Apps.resolve(try a.str("app"))
        let win = AX.window(AXUIElementCreateApplication(app.processIdentifier))
        guard let b = AX.attr(win, kAXCloseButtonAttribute) else { throw JinnError("that window has no close button") }
        let e = AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString)
        guard e == .success else { throw JinnError("could not close: \(AX.describe(e))") }
        return "Closed the window of \(app.localizedName ?? "app")."
    },
    Tool(name: "activate_app", description: "Bring an app to the front (switch to it). Opens it first if it is not running.",
         params: ["app": "App name"], risk: .app("app")) { a in
        let name = try a.str("app")
        if (try? Apps.resolve(name)) == nil {
            try Apps.launch(name)
            for _ in 0..<25 where (try? Apps.resolve(name)) == nil { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        let app = try Apps.resolve(name)
        app.activate(options: [.activateIgnoringOtherApps])
        return "\(app.localizedName ?? name) is in front."
    },
    Tool(name: "hide_app", description: "Hide an app's windows (like Cmd+H).", params: ["app": "Running app name"], risk: .app("app")) { a in
        let app = try Apps.resolve(try a.str("app"))
        app.hide()
        return "Hid \(app.localizedName ?? "app")."
    },
    Tool(name: "find_chat", description: "List the chats in a chat app (WhatsApp, Telegram, Slack, Discord) whose name matches, best first, so the user can pick. Read-only. With no contact, lists the visible chats.",
         params: ["app": "Chat app name", "contact": "(optional) name to look for"], risk: .app("app")) { a in
        let app = try Apps.resolve(try a.str("app"))
        let snap = try await Snapshot.take(app)
        let q = a.opt("contact")
        if q.isEmpty {
            return snap.visible().filter { $0.interactive && !$0.label.isEmpty && !AX.textual.contains($0.role) }.map { chatTitle($0.label) }.joined(separator: "\n")
        }
        let m = chatMatches(q, in: snap)
        return m.isEmpty ? "No visible chat matches \"\(q)\". send_chat will search the whole app." : m.prefix(8).map { "\($0.head) (\(Int($0.score * 100))%)" }.joined(separator: "\n")
    },
    Tool(name: "send_chat", description: "Send a message to a person or group in a chat app (WhatsApp, Telegram, Slack, Discord). Brings the app to the front, finds the chat by name (spelling may differ slightly), checks the text reached the message box, then sends. Asks the user first. If it fails, report why; do not retry by hand.",
         params: ["app": "Chat app name, e.g. WhatsApp", "contact": "Contact or group name", "text": "Message to send"],
         risk: .confirm, alwaysAsk: true) { a in
        let name = try a.str("app"), contact = try a.str("contact"), text = try a.str("text")
        guard AXIsProcessTrusted() else { Permissions.askAccessibility(); throw JinnError.permission("Accessibility") }
        return try await withHUDHidden { () async throws -> String in
            if (try? Apps.resolve(name)) == nil {
                try Apps.launch(name)
                for _ in 0..<40 where (try? Apps.resolve(name)) == nil { try await Task.sleep(nanoseconds: 200_000_000) }
            }
            let app = try Apps.resolve(name)
            let pid = app.processIdentifier, shown = app.localizedName ?? name
            app.activate(options: [.activateIgnoringOtherApps])
            for _ in 0..<15 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { try await Task.sleep(nanoseconds: 200_000_000) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw JinnError("\(shown) would not come to the front; nothing was sent") }
            // pid-0 input goes to whatever is focused: re-check right before every keystroke
        func front() throws { guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw JinnError("\(shown) lost focus; stopped before typing, nothing was sent") } }
        func look() async throws -> Snapshot { try await Task.sleep(nanoseconds: 700_000_000); return try await Snapshot.take(app) }
            func focus(_ n: Node, _ s: Snapshot) async throws {
                // text boxes take AX focus directly; everything else gets a real click
                if !AX.textual.contains(n.role) || AXUIElementSetAttributeValue(n.el, kAXFocusedAttribute as CFString, true as CFBoolean) != .success {
                    _ = try await Click.perform(n, in: s, appPID: pid, right: false, double: false)
                }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            // WhatsApp's Search is a button that opens the field; other apps have a text field
            let isSearch: (Node) -> Bool = { ($0.role == "AXButton" || AX.textual.contains($0.role)) && $0.label.lowercased().contains("search") }

            // 1. the chat is often already in the list; otherwise search for it
            var snap = try await Snapshot.take(app)
            var found = chatMatches(contact, in: snap)
            if found.isEmpty {
                if let f = snap.visible().first(where: isSearch) { try await focus(f, snap) }
                else { let (c, fl) = try Keys.parse(chatSearchKey[app.bundleIdentifier?.lowercased() ?? ""] ?? "cmd+f"); try front(); await Input.key(0, c, flags: fl) }
                // the field keeps the previous query: clear it, but only once it verifiably has focus (Delete elsewhere could act on a chat)
                let opened = try await look()
                if let field = opened.visible().first(where: { AX.textual.contains($0.role) && isSearch($0) }) {
                    AXUIElementSetAttributeValue(field.el, kAXFocusedAttribute as CFString, true as CFBoolean)
                    if (AX.attr(field.el, kAXFocusedAttribute) as? Bool) == true { try front(); await Input.key(0, 0, flags: .maskCommand); try front(); await Input.key(0, 51) } // select all, delete
                }
                try front(); await Input.type(0, contact)
                snap = try await look()
                found = chatMatches(contact, in: snap)
            }

            // 2. closest spelling wins; a near tie is ambiguous and nothing is sent
            guard let top = found.first else { throw JinnError("no chat matching \"\(contact)\" found in \(shown); nothing was sent") }
            if found.count > 1, found[1].score >= top.score - 0.05 {
                throw JinnError("several chats match \"\(contact)\": \(found.prefix(4).map(\.head).joined(separator: " | ")). Tell the user these names and ask which one; nothing was sent")
            }
            try await focus(top.node, snap)
            snap = try await look()

            // 3. type into the message box and make sure the text is really there before sending
            let boxes = snap.visible().filter { AX.textual.contains($0.role) && !isSearch($0) }
            guard let box = boxes.first(where: { $0.label.lowercased().contains("message") || $0.label.lowercased().hasPrefix("type") }) ?? boxes.last
            else { throw JinnError("opened \(top.head) but found no message box; nothing was sent") }
            if box.secure { throw JinnError.blocked("password field") }
            try await focus(box, snap)
            try front(); await Input.type(0, text)
            let probe = String(text.prefix(20)).lowercased()
            snap = try await look()
            guard snap.nodes.contains(where: { AX.textual.contains($0.role) && $0.value.lowercased().contains(probe) }) else {
                throw JinnError("typing did not reach the message box of \(top.head); nothing was sent")
            }
            try front(); await Input.key(0, try Keys.parse("Return").code)
            snap = try await look()
            let seen = snap.nodes.contains { !AX.textual.contains($0.role) && ($0.label + $0.value).lowercased().contains(probe) }
            return seen ? "Sent to \(top.head) in \(shown)." : "Pressed Return in \(top.head)'s chat but could not see the message appear; ask the user to check \(shown)."
        }
    },
]

/// Jinn's own HUD keeps keyboard focus even when another app is in front, so typed text would land in it.
/// Hide it while typing into other apps, and bring it back (with the result) afterwards.
func withHUDHidden<T>(_ body: () async throws -> T) async rethrows -> T {
    await MainActor.run { HUDController.shared.hide() }
    defer { Task { @MainActor in HUDController.shared.show() } }
    return try await body()
}

/// Chat row labels look like "Name, last message, time": the name is the part before the first comma.
func chatTitle(_ label: String) -> String {
    // apps like WhatsApp wrap text in invisible direction marks
    let clean = label.filter { !"\u{200E}\u{200F}\u{2066}\u{2067}\u{2068}\u{2069}".contains($0) }
    return String(clean.split(separator: ",", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Chat buttons in the current view whose name matches. First the strict reading (query words match the title's
/// first words, so "Start video call with X" does not count), then any-word matching. Best first, one entry per title.
func chatMatches(_ query: String, in snap: Snapshot) -> [(head: String, node: Node, score: Double)] {
    let rows = snap.visible().filter { $0.interactive && !$0.label.isEmpty && !AX.textual.contains($0.role) && !chatTitle($0.label).hasPrefix("Start ") } // not call buttons
    for ordered in [true, false] {
        let hits = rows.map { (head: chatTitle($0.label), node: $0, score: nameScore(query, $0.label, ordered: ordered)) }.filter { $0.score >= 0.8 }
        let best = Dictionary(grouping: hits, by: { $0.head.lowercased() }).values
            .compactMap { g in g.min { ($0.node.frame?.minX ?? .infinity) < ($1.node.frame?.minX ?? .infinity) } } // sidebar row, not the header
            .sorted { $0.score > $1.score }
        if !best.isEmpty { return best }
    }
    return []
}

func editDistance(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    var row = Array(0...b.count)
    for i in 1...max(a.count, 1) where !a.isEmpty {
        var prev = row[0]; row[0] = i
        for j in 1...max(b.count, 1) where !b.isEmpty {
            let cur = row[j]
            row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
            prev = cur
        }
    }
    return a.isEmpty ? b.count : row[b.count]
}

/// 0...1: how well every word of `query` matches some word of the chat title (typos like Somaraj/Somraj score high).
func nameScore(_ query: String, _ label: String, ordered: Bool = false) -> Double {
    func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
    let q = words(query), w = words(chatTitle(label))
    guard !q.isEmpty, !w.isEmpty else { return 0 }
    func sim(_ qt: String, _ wt: String) -> Double { wt.hasPrefix(qt) ? 1 : 1 - Double(editDistance(qt, wt)) / Double(max(qt.count, wt.count)) }
    let each = ordered ? q.enumerated().map { $0.offset < w.count ? sim($0.element, w[$0.offset]) : 0 }
                       : q.map { qt in w.map { sim(qt, $0) }.max()! }
    return each.reduce(0, +) / Double(each.count)
}
