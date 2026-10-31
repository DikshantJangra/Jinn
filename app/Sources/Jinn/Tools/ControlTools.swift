import AppKit
import ApplicationServices

private let chatSearchKey: [String: String] = ["com.tinyspeck.slackmacgap": "cmd+k", "com.hnc.discord": "cmd+k"]

let controlTools: [Tool] = [
    Tool(name: "quit_app", description: "Quit a running Mac app (like Cmd+Q). Unsaved work may prompt in the app.",
         params: ["app": "Running app name"], risk: .app("app")) { a in
        let app = try Apps.resolve(try a.str("app"))
        guard app.terminate() else { throw JinnError("\(app.localizedName ?? "app") refused to quit") }
        if let url = app.bundleURL { Undo.shared.record("quit \(app.localizedName ?? "app")") { _ = try Shell.run("/usr/bin/open", [url.path]); return "reopened it (unsaved work is not restored)" } }
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
        Undo.shared.record("hid \(app.localizedName ?? "app")") { app.unhide(); return "shown again" }
        return "Hid \(app.localizedName ?? "app")."
    },
    Tool(name: "find_chat", description: "List the chats in a chat app (WhatsApp, Telegram, Slack, Discord) whose name matches, best first, so the user can pick. Read-only. With no contact, lists the visible chats.",
         params: ["app": "Chat app name", "contact": "(optional) name to look for"], risk: .app("app")) { a in
        let app = try Apps.resolve(try a.str("app"))
        let snap = try await Snapshot.take(app, main: true)
        let q = a.opt("contact")
        if q.isEmpty {
            return snap.visible().filter { $0.interactive && !$0.label.isEmpty && !AX.textual.contains($0.role) }.map { chatTitle($0.label) }.joined(separator: "\n")
        }
        let m = chatMatches(q, in: snap)
        if m.isEmpty, let open = openChatTitle(q, in: snap) { return "\(open) (already open)" }
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
            // always read the main window: a contact card or popup can hold focus and hides the real UI
            func look() async throws -> Snapshot { try await Task.sleep(nanoseconds: 700_000_000); AX.closeExtraWindows(AXUIElementCreateApplication(pid)); return try await Snapshot.take(app, main: true) }
            func focus(_ n: Node, _ s: Snapshot) async throws {
                if !AX.textual.contains(n.role) || AXUIElementSetAttributeValue(n.el, kAXFocusedAttribute as CFString, true as CFBoolean) != .success {
                    _ = try await Click.perform(n, in: s, appPID: pid, right: false, double: false)
                }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            let isSearch: (Node) -> Bool = { ($0.role == "AXButton" || AX.textual.contains($0.role)) && $0.label.lowercased().contains("search") }

            AX.closeExtraWindows(AXUIElementCreateApplication(pid))
            var snap = try await Snapshot.take(app, main: true)
            var found = chatMatches(contact, in: snap)
            let alreadyOpen = found.isEmpty ? openChatTitle(contact, in: snap) : nil // the wanted chat is on screen already
            if found.isEmpty && alreadyOpen == nil {
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

            var head = alreadyOpen ?? ""
            if alreadyOpen == nil {
            guard let top = found.first else { throw JinnError("no chat matching \"\(contact)\" found in \(shown); nothing was sent") }
            if found.count > 1, found[1].score >= top.score - 0.05 {
                throw JinnError("several chats match \"\(contact)\": \(found.prefix(4).map(\.head).joined(separator: " | ")). Tell the user these names and ask which one; nothing was sent")
            }
            head = top.head
            try await focus(top.node, snap)
            snap = try await look()
            }
            // the chat must really be open (its name shows in the pane right of the list), not a profile or the same list
            let edge = sidebarEdge(snap), want = head.lowercased()
            guard snap.nodes.contains(where: { ($0.frame?.minX ?? 0) > edge && ($0.label + $0.value).lowercased().contains(want) }),
                  snap.nodes.contains(where: { AX.textual.contains($0.role) && ($0.frame?.minX ?? 0) > edge })
            else { throw JinnError("clicked \(head) but the chat did not open (no message pane); nothing was sent") }

            let boxes = snap.visible().filter { AX.textual.contains($0.role) && !isSearch($0) && ($0.frame?.minX ?? .infinity) > edge }
            guard let box = boxes.first(where: { $0.label.lowercased().contains("message") || $0.label.lowercased().hasPrefix("type") }) ?? boxes.last
            else { throw JinnError("opened \(head) but found no message box; nothing was sent") }
            if box.secure { throw JinnError.blocked("password field") }
            try await focus(box, snap)
            try front(); await Input.type(0, text)
            let probe = String(text.prefix(20)).lowercased()
            snap = try await look()
            guard snap.nodes.contains(where: { AX.textual.contains($0.role) && $0.value.lowercased().contains(probe) }) else {
                throw JinnError("typing did not reach the message box of \(head); nothing was sent")
            }
            try front(); await Input.key(0, try Keys.parse("Return").code)
            snap = try await look()
            let seen = snap.nodes.contains { !AX.textual.contains($0.role) && ($0.label + $0.value).lowercased().contains(probe) }
            return seen ? "Sent to \(head) in \(shown)." : "Pressed Return in \(head)'s chat but could not see the message appear; ask the user to check \(shown)."
        }
    },
]

func withHUDHidden<T>(_ body: () async throws -> T) async rethrows -> T {
    let was = await MainActor.run { HUDController.shared.suspend() }
    defer { Task { @MainActor in HUDController.shared.resume(was) } }
    return try await body()
}

func chatTitle(_ label: String) -> String {
    let clean = label.filter { !"\u{200E}\u{200F}\u{2066}\u{2067}\u{2068}\u{2069}".contains($0) }
    return String(clean.split(separator: ",", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Right edge of the chat list: the splitter if the app has one, else 45% across the window.
func sidebarEdge(_ snap: Snapshot) -> CGFloat {
    if let sp = snap.nodes.first(where: { $0.role == "AXSplitter" })?.frame { return sp.minX + 6 }
    guard let w = snap.nodes.first?.frame else { return .infinity }
    return w.minX + w.width * 0.45
}

/// Title of the chat that is already open in the right-hand pane (its header button) when it matches the query.
func openChatTitle(_ query: String, in snap: Snapshot) -> String? {
    let edge = sidebarEdge(snap)
    // only the conversation header band counts (a message bubble or link that merely contains the name must not), and near-exact
    let top = (snap.nodes.first?.frame?.minY ?? 0) + 110
    return snap.visible().first { $0.interactive && ($0.frame.map { $0.minX > edge && $0.minY < top } ?? false) && !chatTitle($0.label).hasPrefix("Start ")
        && nameScore(query, $0.label, ordered: true) >= 0.95 }.map { chatTitle($0.label) }
}

func chatMatches(_ query: String, in snap: Snapshot) -> [(head: String, node: Node, score: Double)] {
    // only the chat list on the left: the open chat's header button (right) opens the contact card instead of the chat
    let edge = sidebarEdge(snap)
    let rows = snap.visible().filter { $0.interactive && !$0.label.isEmpty && !AX.textual.contains($0.role) && !chatTitle($0.label).hasPrefix("Start ")
        && ($0.frame.map { $0.minX < edge } ?? true) }
    for ordered in [true, false] {
        let hits = rows.map { (head: chatTitle($0.label), node: $0, score: nameScore(query, $0.label, ordered: ordered)) }.filter { $0.score >= 0.8 }
        let best = Dictionary(grouping: hits, by: { $0.head.lowercased() }).values
            .compactMap { g in g.min { ($0.node.frame?.minX ?? .infinity) < ($1.node.frame?.minX ?? .infinity) } }
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

func nameScore(_ query: String, _ label: String, ordered: Bool = false) -> Double {
    func words(_ s: String) -> [String] { s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init) }
    let q = words(query), w = words(chatTitle(label))
    guard !q.isEmpty, !w.isEmpty else { return 0 }
    func sim(_ qt: String, _ wt: String) -> Double { wt.hasPrefix(qt) ? 1 : 1 - Double(editDistance(qt, wt)) / Double(max(qt.count, wt.count)) }
    let each = ordered ? q.enumerated().map { $0.offset < w.count ? sim($0.element, w[$0.offset]) : 0 }
                       : q.map { qt in w.map { sim(qt, $0) }.max()! }
    return each.reduce(0, +) / Double(each.count)
}
