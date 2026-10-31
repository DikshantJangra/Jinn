import Foundation

enum Prune {
    static let interactive: Set<String> = AX.clickable.union(AX.textual)
    static let selectable: Set<String> = ["AXButton", "AXLink", "AXCell", "AXRow", "AXMenuItem", "AXRadioButton", "AXCheckBox", "AXTab"]

    private static let roleNames: [String: String] = [
        "AXStaticText": "text", "AXTextField": "text field", "AXTextArea": "text area", "AXButton": "button", "AXRadioButton": "radio",
        "AXCheckBox": "checkbox", "AXPopUpButton": "popup", "AXMenuButton": "menu button", "AXDisclosureTriangle": "disclosure",
        "AXSlider": "slider", "AXComboBox": "combo box", "AXLink": "link", "AXMenuItem": "menu item", "AXMenu": "menu",
        "AXMenuBar": "menu bar", "AXMenuBarItem": "menu bar item", "AXTab": "tab", "AXTabGroup": "tab group", "AXToolbar": "toolbar",
        "AXWindow": "window", "AXSheet": "sheet", "AXDialog": "dialog", "AXScrollArea": "scroll area", "AXTable": "table",
        "AXOutline": "outline", "AXRow": "row", "AXCell": "cell", "AXList": "list", "AXGroup": "group", "AXImage": "image",
        "AXSearchField": "search field", "AXWebArea": "web area", "AXSplitGroup": "split group",
    ]

    static func display(_ role: String) -> String {
        roleNames[role] ?? (role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased())
    }

    static func children(_ n: [Node]) -> [Int: [Int]] {
        var kids: [Int: [Int]] = [:]
        var stack: [Int] = []
        for i in n.indices {
            while let top = stack.last, n[top].depth >= n[i].depth { stack.removeLast() }
            if let p = stack.last { kids[p, default: []].append(i) }
            stack.append(i)
        }
        return kids
    }

    static func apply(_ n: inout [Node]) -> Set<Int> {
        let kids = children(n)
        var removed = Set<Int>()

        for i in n.indices.dropLast() where !removed.contains(i) {
            let a = n[i], b = n[i + 1]
            if a.role == "AXStaticText", !a.label.isEmpty, interactive.contains(b.role), b.label.isEmpty, a.depth == b.depth {
                n[i + 1].label = a.label
                removed.insert(i)
            }
        }

        for i in n.indices where selectable.contains(n[i].role) {
            guard let ks = kids[i], ks.allSatisfy({ !interactive.contains(n[$0].role) && (kids[$0] ?? []).isEmpty }) else { continue }
            if n[i].label.isEmpty { n[i].label = ks.map { n[$0].label }.filter { !$0.isEmpty }.joined(separator: " ") }
            ks.forEach { removed.insert($0) }
        }

        for (_, ks) in kids {
            var first: Int?
            for c in ks where !removed.contains(c) {
                if n[c].role == "AXStaticText", !n[c].label.isEmpty, (kids[c] ?? []).isEmpty {
                    if let f = first { n[f].label += " " + n[c].label; removed.insert(c) } else { first = c }
                } else { first = nil }
            }
        }
        return removed
    }
}
