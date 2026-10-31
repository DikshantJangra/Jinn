import AppKit
import ApplicationServices

struct Node {
    let index: Int
    let depth: Int
    let role: String
    var label: String
    let value: String
    let frame: CGRect?
    let actions: [String]
    let el: AXUIElement
    var subrole = ""

    var secure: Bool { subrole == "AXSecureTextField" || role == "AXSecureTextField" }

    var interactive: Bool { AX.clickable.contains(role) || AX.textual.contains(role) || actions.contains("AXPress") }
    var center: CGPoint? { frame.map { CGPoint(x: $0.midX, y: $0.midY) } }
}

final class Snapshot {
    let pid: pid_t, app: String, bundle: String, window: String
    let nodes: [Node]

    init(pid: pid_t, app: String, bundle: String, window: String, nodes: [Node]) {
        self.pid = pid; self.app = app; self.bundle = bundle; self.window = window; self.nodes = nodes
    }

    private static let lock = NSLock()
    private static var woken = Set<pid_t>()
    private static var latest: [pid_t: Snapshot] = [:]
    static func latest(_ pid: pid_t) -> Snapshot? { lock.withLock { latest[pid] } }

    @discardableResult
    static func take(_ app: NSRunningApplication, main: Bool = false) async throws -> Snapshot {
        guard AXIsProcessTrusted() else { throw JinnError.permission("Accessibility") }
        // Chromium builds its web accessibility tree lazily: ask once, give it a moment, or the page looks empty
        if Chrome.isBrowser(app), lock.withLock({ woken.insert(app.processIdentifier).inserted }) {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, true as CFBoolean)
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, true as CFBoolean)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        let snap = try await retry(3, base: 0.3) { () -> Snapshot in
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 2)
            AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, true as CFBoolean)
            let win = main ? AX.largestWindow(root) : AX.window(root)
            var nodes: [Node] = []
            var stack: [(AXUIElement, Int)] = [(win, 0)]
            while let (e, d) = stack.popLast(), nodes.count < 3000 {
                let b = AX.batch(e)
                let role = b[kAXRoleAttribute] as? String ?? ""
                let label = [b[kAXTitleAttribute], b[kAXDescriptionAttribute], b[kAXPlaceholderValueAttribute]]
                    .compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
                var value = ""
                if let v = b[kAXValueAttribute] { if let s = v as? String { value = s } else if let n = v as? NSNumber { value = n.stringValue } }
                var frame: CGRect?
                if let p = AX.point(b[kAXPositionAttribute]), let s = AX.size(b[kAXSizeAttribute]) { frame = CGRect(origin: p, size: s) }
                let interactive = AX.clickable.contains(role) || AX.textual.contains(role)
                let subrole = b[kAXSubroleAttribute] as? String ?? ""
                if subrole == "AXSecureTextField" { value = "" }
                nodes.append(Node(index: nodes.count, depth: d, role: role, label: label, value: value, frame: frame,
                                  actions: interactive ? AX.actions(e) : [], el: e, subrole: subrole))
                if d < 40 { for c in ((b[kAXChildrenAttribute] as? [AXUIElement]) ?? []).reversed() { stack.append((c, d + 1)) } }
            }
            guard nodes.count > 1 else { throw JinnError("\(app.localizedName ?? "app") exposes no accessibility tree (no window open, or the app blocks it)") }
            return Snapshot(pid: app.processIdentifier, app: app.localizedName ?? "?", bundle: app.bundleIdentifier ?? "?",
                            window: AX.str(win, kAXTitleAttribute), nodes: nodes)
        }
        lock.withLock { latest[snap.pid] = snap }
        return snap
    }

    private static func short(_ role: String) -> String { Prune.display(role) }

    private func line(_ n: Node) -> String {
        var s = String(repeating: " ", count: min(n.depth, 10)) + "[\(n.index)] " + (n.secure ? "password field" : Snapshot.short(n.role))
        if !n.label.isEmpty { s += " \"\(n.label.prefix(70))\"" }
        if !n.value.isEmpty, n.value != n.label { s += " = \"\(n.value.prefix(70))\"" }
        return s
    }

    func render(budget: Int = 6000) -> String {
        let ranked = visible().compactMap { n -> (Node, Int)? in
            n.interactive ? (n, 2) : (!n.label.isEmpty || !n.value.isEmpty ? (n, 1) : nil)
        }.sorted { ($0.1, $1.0.index) > ($1.1, $0.0.index) }
        var used = 0, keep: [Node] = []
        for (n, _) in ranked {
            let c = line(n).count + 1
            if used + c > budget { continue }
            used += c; keep.append(n)
        }
        let dropped = ranked.count - keep.count
        var out = "App: \(app) (\(bundle)), window \"\(window)\", \(nodes.count) elements\n"
        out += keep.sorted { $0.index < $1.index }.map(line).joined(separator: "\n")
        if dropped > 0 { out += "\n… \(dropped) lower-priority elements pruned" }
        return out
    }

    func ancestors(of index: Int) -> [Node] {
        guard nodes.indices.contains(index) else { return [] }
        var out: [Node] = [], depth = nodes[index].depth
        for i in stride(from: index - 1, through: 0, by: -1) where nodes[i].depth < depth {
            out.append(nodes[i]); depth = nodes[i].depth
        }
        return out
    }

    func visible() -> [Node] {
        var n = nodes
        let hidden = Prune.apply(&n)
        return n.filter { !hidden.contains($0.index) }
    }

    static func refetch(_ old: Node, in new: Snapshot) -> Result<Node, JinnError> {
        let m = new.nodes.filter { $0.role == old.role && $0.label == old.label }
        if m.count == 1 { return .success(m[0]) }
        if m.isEmpty { return .failure(JinnError("[\(old.index)] \(old.label.isEmpty ? old.role : "\"\(old.label)\"") is gone; call app_state again")) }
        guard let oc = old.center else { return .failure(JinnError("[\(old.index)] is ambiguous after the UI changed; call app_state again")) }
        let ranked = m.compactMap { n in n.center.map { (n, hypot($0.x - oc.x, $0.y - oc.y)) } }.sorted { $0.1 < $1.1 }
        if let a = ranked.first, ranked.count == 1 || ranked[1].1 - a.1 > 2 { return .success(a.0) }
        return .failure(JinnError("[\(old.index)] \"\(old.label)\" is ambiguous after the UI changed; call app_state again"))
    }

    static func diff(_ old: Snapshot?, _ new: Snapshot) -> String {
        guard let old else { return "" }
        func bag(_ s: Snapshot) -> [String: Int] {
            var m: [String: Int] = [:]
            for n in s.nodes where n.interactive || !n.label.isEmpty || !n.value.isEmpty {
                m[short(n.role) + " \"\(n.label.prefix(50))\"" + (n.value.isEmpty ? "" : " = \"\(n.value.prefix(50))\""), default: 0] += 1
            }
            return m
        }
        let a = bag(old), b = bag(new)
        let added = b.filter { $0.value > (a[$0.key] ?? 0) }.keys.sorted().prefix(8).map { "+ " + $0 }
        let removed = a.filter { $0.value > (b[$0.key] ?? 0) }.keys.sorted().prefix(8).map { "- " + $0 }
        let all = added + removed
        return all.isEmpty ? "No visible change (the action may not have taken effect)." : "Changed:\n" + all.joined(separator: "\n")
    }
}
