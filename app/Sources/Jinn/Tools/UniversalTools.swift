import AppKit

/// Wording that sends, submits, pays or destroys. Any act on such a target asks the user first, for every app and site.
func looksRisky(_ s: String) -> Bool {
    Chrome.risky.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
}

/// What the last `look` showed. `act` may only touch things that were actually seen, so a model cannot click an invented button.
enum Observed {
    enum Kind { case none, web, ax, ocr }
    private static let lock = NSLock()
    private static var kind = Kind.none, labels: [Int: String] = [:], appName = ""
    static func set(_ k: Kind, app: String, labels l: [Int: String]) { lock.withLock { kind = k; appName = app; labels = l } }
    static var current: Kind { lock.withLock { kind } }
    static var app: String { lock.withLock { appName } }
    static func label(_ i: Int) -> String? { lock.withLock { labels[i] } }
    /// Visible text -> the element of the last look it names: exact (case-insensitive) first, else the first that contains it.
    static func resolve(_ text: String) -> (id: Int, label: String)? {
        let q = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        return lock.withLock {
            let all = labels.sorted { $0.key < $1.key }.filter { !$0.value.isEmpty }
            return (all.first { $0.value.lowercased() == q } ?? all.first { $0.value.lowercased().contains(q) }).map { ($0.key, $0.value) }
        }
    }
    /// "#12" or "[12]" is an id; bare numbers are text ("2024").
    static func index(_ target: String) -> Int? {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("#") || t.hasPrefix("[") else { return nil }
        return Int(t.trimmingCharacters(in: CharacterSet(charactersIn: "#[] ")))
    }
}

/// The label of the element an act will really hit, from the last look. Model-supplied `label` args are never trusted.
func resolvedLabel(_ a: [String: Any]) -> String {
    let t = a.opt("target")
    if let i = Observed.index(t) { return Observed.label(i) ?? "" }
    return Observed.resolve(t)?.label ?? ""
}

/// Approval needed for this exact call: the words typed, the element it resolves to, any key except plain navigation keys (Return sends in chat and mail boxes), or multi-line text.
func actNeedsApproval(_ a: [String: Any]) -> Bool {
    switch a.opt("action").lowercased() {
    case "scroll": return false
    // allowlist: only plain navigation keys skip approval; Return/Enter/space/Delete and every modifier combo ask
    case "press": return !["up", "down", "left", "right", "pageup", "pagedown", "home", "end", "escape", "esc", "tab"].contains(a.opt("text").lowercased().trimmingCharacters(in: .whitespaces))
    case "type": return a.opt("text").contains("\n")
    default: return looksRisky(a.opt("target")) || looksRisky(resolvedLabel(a))
    }
}

/// The app's focused element accepts text (text field/area, or an editable web element).
private func focusedEditable(_ pid: pid_t) -> Bool {
    guard let f = AX.attr(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute) else { return false }
    let el = f as! AXUIElement
    return AX.textual.contains(AX.str(el, kAXRoleAttribute)) || AX.attr(el, "AXEditableAncestor") != nil
}
private func tool(_ name: String) -> Tool { allTools.first { $0.name == name }! }

private struct WebState { let url: String, title: String, items: [String] }

private func webState(_ tab: String = "") async throws -> WebState {
    let raw = try await Chrome.eval(Chrome.run("JSON.stringify({url:location.href,title:document.title,els:listJ()})"), tab: tab)
    guard let o = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else { throw JinnError("could not read the page") }
    let els = (o["els"] as? [[String: String]]) ?? []
    return WebState(url: o["url"] as? String ?? "", title: o["title"] as? String ?? "", items: els.map { "\($0["role"] ?? "") \"\($0["label"] ?? "")\"" })
}

/// What changed on a page: the verification signal the model must read before it claims anything.
private func webDiff(_ a: WebState, _ b: WebState) -> String {
    var lines: [String] = []
    if a.url != b.url { lines.append("page is now: \(b.title) (\(b.url))") }
    else if a.title != b.title { lines.append("title is now: \(b.title)") }
    let old = Set(a.items), new = Set(b.items)
    lines += new.subtracting(old).sorted().prefix(8).map { "+ " + $0 } + old.subtracting(new).sorted().prefix(5).map { "- " + $0 }
    return lines.isEmpty ? "No visible change (the action may not have taken effect)." : "Changed:\n" + lines.joined(separator: "\n")
}

private func webAct(_ action: String, target: String, label: String, text: String) async throws -> String {
    let before = try await webState()
    var r = ""
    let t = Chrome.jsString(target), l = Chrome.jsString(label)
    switch action {
    case "click":
        r = try await Chrome.eval(Chrome.run("clickT(\(t),\(l))"))
    case "type":
        r = try await Chrome.eval(Chrome.run("typeT(\(t),\(Chrome.jsString(text)),\(l))"))
        if r == "ok" { try await Task.sleep(nanoseconds: 300_000_000); return "typed into \(label.isEmpty ? (target.isEmpty ? "the focused box" : target) : "\"\(label)\"")\nChanged:\n+ text entered" }
    case "press":
        let (code, flags) = try Keys.parse(text)
        await Input.key(Chrome.pid, code, flags: flags)
        r = "pressed \(text)"
    default: // scroll
        r = try await Chrome.eval(Chrome.run("(window.scrollBy(0,\(text == "up" ? -1 : 1)*innerHeight*0.8),'scrolled')"))
    }
    if r.hasPrefix("not found") || r.hasPrefix("no editable") || r.hasPrefix("refused") || r == "text did not land" { throw JinnError(r) }
    try await Task.sleep(nanoseconds: 900_000_000)
    return r + "\n" + webDiff(before, try await webState())
}

private func axLabelArgs(_ target: String, _ label: String, app: String) -> [String: Any] {
    if let i = Observed.index(target) { return ["app": app, "element": String(i)] }
    return ["app": app, "label": target.isEmpty ? label : target]
}

let universalTools: [Tool] = [
    Tool(name: "look", description: "See the screen. Lists what can be clicked or typed in the front app (or the named app) as #id role \"label\", plus visible text. Works for any app or website. Call before act, and again to check a result.",
         params: ["app": "(optional) app name; default is the app in front", "full": "(optional) true to read the whole page text, e.g. a long email"], risk: .app("app")) { a in
        let app = try Apps.target(a.opt("app")), name = app.localizedName ?? "app"
        var webNote = ""
        if Chrome.isBrowser(app) {
            let full = a.opt("full") == "true"
            let raw: String?
            do { raw = try await Chrome.eval(Chrome.run("JSON.stringify({url:location.href,title:document.title,text:(document.body.innerText||'').replace(/\\s+/g,' ').slice(0,\(full ? 8000 : 1200)),els:listJ()})")) }
            catch { raw = nil; webNote = "(browser scripting is off: \(error.localizedDescription.prefix(160)))\n" }
            if let raw, let o = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
                let els = (o["els"] as? [[String: String]]) ?? []
                Observed.set(.web, app: name, labels: Dictionary(uniqueKeysWithValues: els.enumerated().map { ($0, $1["label"] ?? "") }))
                return "\(name) page: \(o["title"] ?? "") (\(o["url"] ?? ""))\nText: \(o["text"] ?? "")\nElements:\n"
                    + els.enumerated().map { "#\($0) \($1["role"] ?? "") \"\($1["label"] ?? "")\"" }.joined(separator: "\n")
            }
        }
        if let s = try? await Snapshot.take(app) {
            Observed.set(.ax, app: name, labels: Dictionary(uniqueKeysWithValues: s.nodes.map { ($0.index, $0.label) }))
            var out = webNote + s.render() + (appGuidance[s.bundle.lowercased()].map { "\nHint: \($0)" } ?? "")
            if s.nodes.filter(\.interactive).count < 5 {
                // thin tree (browsers, Electron): read the pixels too, and let act click what the text names
                do {
                    let items = try await Screen.read(app).items
                    var labels = Dictionary(uniqueKeysWithValues: s.nodes.map { ($0.index, $0.label) })
                    var n = (labels.keys.max() ?? 0) + 1
                    var lines: [String] = []
                    for it in items { labels[n] = it.text; lines.append("[\(n)] text \"\(it.text.prefix(90))\""); n += 1 }
                    Observed.set(.ocr, app: name, labels: labels)
                    out += "\nFew accessible elements, so this is the text read from the pixels (act click with the text, then look again):\n" + lines.joined(separator: "\n")
                } catch { out += "\n(could not read the screen text: \(error.localizedDescription))" }
            }
            return out
        }
        let items = try await Screen.read(app).items
        Observed.set(.ocr, app: name, labels: Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0, $1.text) }))
        return "\(name) exposes no accessibility tree. Text by OCR:\n" + items.enumerated().map { "#\($0) \"\($1.text.prefix(90))\"" }.joined(separator: "\n")
    },

    Tool(name: "act", description: "Do one thing on screen in any app or website, and get back what changed. action: click (target = #id from look, or the element's visible text), type (text goes into target, or the focused box), press (text = key like Return, Tab, cmd+a), scroll (text = up or down), wait (text = text to wait for). Only targets you saw in look work. Sending, submitting, paying and deleting ask the user.",
         params: ["action": "click, type, press, scroll or wait", "target": "(optional) #id from the latest look, or visible text of the element",
                  "text": "(optional) text to type, key combo to press, or up/down to scroll", "app": "(optional) app name; default is the app in front"],
         risk: .app("app"), askIf: actNeedsApproval) { a in
        let action = try a.str("action").lowercased(), text = a.opt("text")
        var target = a.opt("target")
        guard ["click", "type", "press", "scroll", "wait"].contains(action) else { throw JinnError("action must be click, type, press, scroll or wait") }
        if (action == "click") && target.isEmpty { throw JinnError("click needs a target: a #id from look, or the element's text") }
        if action == "type" && text.isEmpty { throw JinnError("type needs text") }
        if action == "press" && text.isEmpty { throw JinnError("press needs text, e.g. Return") }
        let app = try Apps.target(a.opt("app")), name = app.localizedName ?? "app"
        // grounding: no observation of this app yet, or an id that was never shown -> refuse instead of guessing
        guard Observed.current != .none, Observed.app == name else { throw JinnError("you have not looked at \(name) yet; call look first, then act on what it shows") }
        // resolve what will really be hit; text must name something the last look showed
        var label = ""
        if action == "click" || (action == "type" && !target.isEmpty) {
            if let i = Observed.index(target) {
                guard let l = Observed.label(i) else { throw JinnError("#\(i) was not in the last look; call look again and use an id it shows") }
                label = l
            } else if let r = Observed.resolve(target) { target = "#\(r.id)"; label = r.label }
            else { throw JinnError("nothing labelled \"\(target)\" in the last look; call look again (scroll or open it first if it is not on screen)") }
            // approval was decided on the resolved element too; this is the last line of defence if the two ever disagree
        }
        if action == "wait" { return try await tool("wait_for_text").run(["app": name, "text": text, "seconds": "10"]) }
        // typing needs a text box that has focus: refuse instead of typing into nothing
        if action == "type", target.isEmpty, Observed.current != .web, !focusedEditable(app.processIdentifier) {
            throw JinnError("no text box has focus in \(name), so typing would go nowhere. Click the text box first (for a reply: click Reply, look, then click the box), then type.")
        }
        let busy = try await Interrupt.waitIdle(pid: app.processIdentifier)
        let out: String
        switch Observed.current {
        case .web:
            out = try await webAct(action, target: target, label: label, text: text)
        case .ocr:
            switch action {
            case "click": out = try await tool("click_text").run(["app": name, "text": label.isEmpty ? target : label])
            case "type": out = try await tool("type_text").run(["app": name, "text": text])
            case "press": out = try await tool("press_key").run(["app": name, "key": text])
            default: out = try await tool("scroll").run(["app": name, "direction": text == "up" ? "up" : "down"])
            }
        default: // .ax
            switch action {
            case "click": out = try await tool("click").run(axLabelArgs(target, label, app: name))
            case "type": out = try await tool("type_text").run(axLabelArgs(target, label, app: name).merging(["text": text]) { $1 })
            case "press": out = try await tool("press_key").run(["app": name, "key": text])
            default: out = try await tool("scroll").run(["app": name, "direction": text == "up" ? "up" : "down"])
            }
        }
        return out + Interrupt.note(busy)
    },
]
