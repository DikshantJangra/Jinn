import ApplicationServices
import AppKit
import Foundation

private struct Target {
    let app: NSRunningApplication
    let before: Snapshot?
    let node: Node
}

private func target(_ a: [String: Any]) async throws -> Target {
    let app = try Apps.resolve(try a.str("app"))
    var snap = Snapshot.latest(app.processIdentifier)
    if let i = Int(a.opt("element")) {
        guard let s = snap, s.nodes.indices.contains(i) else { throw JinnError.stale(app.localizedName ?? "app") }
        if AX.alive(s.nodes[i].el) { return Target(app: app, before: s, node: s.nodes[i]) }
        let fresh = try await Snapshot.take(app)
        return Target(app: app, before: fresh, node: try Snapshot.refetch(s.nodes[i], in: fresh).get())
    }
    let label = a.opt("label").lowercased()
    guard !label.isEmpty else { throw JinnError("give element (index from app_state) or label") }
    snap = try await Snapshot.take(app)
    let hits = snap!.visible().filter { !$0.label.isEmpty && $0.label.lowercased().contains(label) }
    guard let n = hits.first(where: { $0.label.lowercased() == label && $0.interactive }) ?? hits.first(where: { $0.interactive }) ?? hits.first
    else { throw JinnError("no element matching '\(label)'; call app_state to see what is there") }
    return Target(app: app, before: snap, node: n)
}

private func observe(_ app: NSRunningApplication, since before: Snapshot?) async -> String {
    try? await Task.sleep(nanoseconds: 300_000_000)
    do { return Snapshot.diff(before, try await Snapshot.take(app)) }
    catch { return "(sent, but could not read the result: \(error.localizedDescription))" }
}

private func finish(_ msg: String, _ t: Target, busy: Bool) async throws -> String {
    msg + Interrupt.note(busy) + "\n" + (await observe(t.app, since: t.before))
}

private func focusedIsSecure(_ app: NSRunningApplication) -> Bool {
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard let f = AX.attr(root, kAXFocusedUIElementAttribute) else { return false }
    return AX.str(f as! AXUIElement, kAXSubroleAttribute) == "AXSecureTextField"
}

private let pick: [String: String] = ["app": "Running app name",
                                      "element": "(optional) element index from the latest app_state",
                                      "label": "(optional) text on the element, if you have no index"]

let axTools: [Tool] = [
    Tool(name: "list_apps", description: "List running Mac apps (name, bundle id, which is frontmost)") { _ in Apps.list() },

    Tool(name: "screen_read", description: "See what is on the user's screen: the frontmost app's window as an indexed element list. For Chrome it returns the page title, URL and text instead. Use for 'what is on my screen'.",
         params: ["app": "(optional) app name; default is the app in front"], risk: .app("app")) { a in
        let app = try Apps.target(a.opt("app"))
        if app.bundleIdentifier?.lowercased().hasPrefix("com.google.chrome") == true, let page = try? await Chrome.eval(Chrome.page) {
            return "Chrome page: " + page
        }
        func ocr(_ why: String) async throws -> String {
            let (_, items) = try await Screen.read(app)
            return "\(why) Text on the window by OCR (use click_text / click_at):\n" + Screen.render(items)
        }
        guard let s = try? await Snapshot.take(app) else { return try await ocr("\(app.localizedName ?? "App") exposes no accessibility tree.") }
        let out = s.render() + (appGuidance[s.bundle.lowercased()].map { "\nHint: \($0)" } ?? "")
        if s.nodes.filter(\.interactive).count < 3, let extra = try? await ocr("Few accessible elements.") { return out + "\n" + extra }
        return out
    },

    Tool(name: "app_state", description: "Read an app's window as an indexed list of UI elements. Call this before clicking or typing in an app; indices are only valid for this reading.",
         params: ["app": "Running app name"], risk: .app("app")) { a in
        let app = try Apps.resolve(try a.str("app"))
        let s = try await Snapshot.take(app)
        let hint = appGuidance[s.bundle.lowercased()].map { "\nHint: \($0)" } ?? ""
        return s.render() + hint
    },

    Tool(name: "click", description: "Click a button, link, menu item, checkbox or tab in an app, without moving the user's mouse. Uses the accessibility press, falling back to a click on the element.",
         params: pick.merging(["button": "(optional) left or right", "double": "(optional) true for a double click"]) { $1 }, risk: .app("app")) { a in
        let t = try await target(a)
        let busy = try await Interrupt.waitIdle(pid: t.app.processIdentifier)
        guard let snap = t.before else { throw JinnError.stale(t.app.localizedName ?? "app") }
        let how = try await Click.perform(t.node, in: snap, appPID: t.app.processIdentifier,
                                          right: a.opt("button") == "right", double: a.opt("double") == "true")
        return try await finish("\(how) [\(t.node.index)] \(t.node.label)", t, busy: busy)
    },

    Tool(name: "set_value", description: "Set the text of a field directly (replaces its content). Instant and needs no focus. Fails in some Electron apps; then use type_text.",
         params: pick.merging(["value": "New text"]) { $1 }, risk: .app("app")) { a in
        let t = try await target(a)
        if t.node.secure { throw JinnError.blocked("Jinn does not fill password fields; ask the user to type it") }
        let busy = try await Interrupt.waitIdle(pid: t.app.processIdentifier)
        let e = AXUIElementSetAttributeValue(t.node.el, kAXValueAttribute as CFString, try a.str("value") as CFString)
        guard e == .success else { throw JinnError("could not set [\(t.node.index)]: \(AX.describe(e)); try type_text") }
        return try await finish("set [\(t.node.index)] \(t.node.label)", t, busy: busy)
    },

    Tool(name: "type_text", description: "Type literal text into an app via keystrokes sent to that app only (the user's keyboard is untouched). Pass element or label to focus a field first.",
         params: pick.merging(["text": "Text to type"]) { $1 }.filter { $0.key != "element" && $0.key != "label" }
            .merging(["element": "(optional) field index to focus first", "label": "(optional) field label to focus first"]) { $1 },
         risk: .app("app")) { a in
        let app = try Apps.resolve(try a.str("app"))
        let hasField = !a.opt("element").isEmpty || !a.opt("label").isEmpty
        let t = hasField ? try await target(a) : nil
        if t?.node.secure == true || (t == nil && focusedIsSecure(app)) { throw JinnError.blocked("Jinn does not type into password fields; ask the user to type it") }
        let busy = try await Interrupt.waitIdle(pid: app.processIdentifier)
        if let t { AXUIElementSetAttributeValue(t.node.el, kAXFocusedAttribute as CFString, true as CFBoolean) }
        if let t, t.node.subrole == "AXSearchField" || t.node.label.lowercased().contains("search") {
            await Input.key(app.processIdentifier, 0, flags: .maskCommand); await Input.key(app.processIdentifier, 51)
        }
        await Input.type(app.processIdentifier, try a.str("text"))
        return "typed" + Interrupt.note(busy) + "\n" + (await observe(app, since: t?.before ?? Snapshot.latest(app.processIdentifier)))
    },

    Tool(name: "press_key", description: "Send a key or shortcut to an app only. Examples: Return, Tab, Escape, cmd+a, cmd+shift+4, ctrl+Left.",
         params: ["app": "Running app name", "key": "Key combo"], risk: .app("app")) { a in
        let app = try Apps.resolve(try a.str("app"))
        let (code, flags) = try Keys.parse(try a.str("key"))
        let busy = try await Interrupt.waitIdle(pid: app.processIdentifier)
        let before = Snapshot.latest(app.processIdentifier)
        await Input.key(app.processIdentifier, code, flags: flags)
        return "pressed \(try a.str("key"))" + Interrupt.note(busy) + "\n" + (await observe(app, since: before))
    },

    Tool(name: "scroll", description: "Scroll a scrollable element (or the window) up or down by pages",
         params: pick.merging(["direction": "up or down", "pages": "(optional) number of pages, default 1"]) { $1 }
            .filter { $0.key != "element" && $0.key != "label" }.merging(["element": "(optional) scroll area index", "label": "(optional) scroll area label"]) { $1 },
         risk: .app("app")) { a in
        let down = a.opt("direction") != "up"
        let pages = max(1, min(10, Int(a.opt("pages")) ?? 1))
        let t = try await target(a.opt("element").isEmpty && a.opt("label").isEmpty ? a.merging(["element": "0"]) { $1 } : a)
        let busy = try await Interrupt.waitIdle(pid: t.app.processIdentifier)
        for _ in 0..<pages {
            if AXUIElementPerformAction(t.node.el, (down ? "AXScrollDownByPage" : "AXScrollUpByPage") as CFString) != .success, let c = t.node.center {
                Input.scroll(t.app.processIdentifier, at: c, dy: down ? -10 : 10)
            }
        }
        return try await finish("scrolled \(down ? "down" : "up") \(pages)", t, busy: busy)
    },

    Tool(name: "perform_action", description: "Run a specific accessibility action on an element, e.g. AXShowMenu, AXIncrement, AXDecrement, AXConfirm, AXCancel. Most reliable way to operate controls.",
         params: pick.merging(["action": "Accessibility action name"]) { $1 }, risk: .app("app")) { a in
        let action = try a.str("action")
        guard action != "AXRaise" else { throw JinnError.blocked("AXRaise would steal the user's focus") }
        let t = try await target(a)
        let busy = try await Interrupt.waitIdle(pid: t.app.processIdentifier)
        let e = AXUIElementPerformAction(t.node.el, action as CFString)
        guard e == .success else { throw JinnError("\(action) on [\(t.node.index)] failed: \(AX.describe(e)). Supported: \(AX.actions(t.node.el).joined(separator: ", "))") }
        return try await finish("performed \(action) on [\(t.node.index)]", t, busy: busy)
    },
]
