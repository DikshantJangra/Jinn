import ApplicationServices
import AppKit

enum Click {
    enum Step: Equatable { case select, press, showMenu, pointer }

    static let selectable: Set<String> = ["AXRow", "AXCell", "AXOutlineRow"]
    static let webContainers: Set<String> = ["AXWebArea"]
    static let pointerPreferred: Set<String> = ["AXLink", "AXButton", "AXGroup", "AXStaticText", "AXImage", "AXCell", "AXRadioButton", "AXCheckBox", "AXMenuItem"]
    static let activation: Set<String> = ["AXPress", "AXConfirm", "AXPick", "AXOpen"]

    static func plan(role: String, actions: [String], inWeb: Bool, right: Bool, double: Bool) -> [Step] {
        if right { return [.showMenu, .pointer] }
        if double { return [.pointer] }
        if selectable.contains(role) { return [.select, .press, .pointer] }
        let forcePointer = !actions.isEmpty && Set(actions).isDisjoint(with: activation) && Prune.interactive.contains(role)
        if forcePointer || (inWeb && pointerPreferred.contains(role)) { return [.pointer, .press] }
        return [.press, .pointer]
    }

    static func perform(_ node: Node, in snap: Snapshot, appPID: pid_t, right: Bool, double: Bool) async throws -> String {
        let inWeb = snap.ancestors(of: node.index).contains { webContainers.contains($0.role) }
        let actions = AX.actions(node.el)
        var lastError = "no way to click it"
        for step in plan(role: node.role, actions: actions, inWeb: inWeb, right: right, double: double) {
            switch step {
            case .select:
                if AXUIElementSetAttributeValue(node.el, kAXSelectedAttribute as CFString, true as CFBoolean) == .success { return "selected" }
            case .showMenu:
                if AXUIElementPerformAction(node.el, "AXShowMenu" as CFString) == .success { return "opened the menu of" }
            case .press:
                let target = actions.contains("AXPress") ? node.el
                    : snap.ancestors(of: node.index).prefix(4).first { AX.actions($0.el).contains("AXPress") }?.el
                if let target {
                    let e = AXUIElementPerformAction(target, kAXPressAction as CFString)
                    if e == .success { return "pressed" }
                    lastError = AX.describe(e)
                }
            case .pointer:
                guard let c = node.center else { lastError = "it has no on-screen position"; continue }
                let pid = AX.pid(node.el)
                await Input.click(pid > 0 ? pid : appPID, at: c, right: right, count: double ? 2 : 1)
                return right ? "right-clicked" : double ? "double-clicked" : "clicked"
            }
        }
        throw JinnError("could not click [\(node.index)]: \(lastError). Try perform_action or a different element.")
    }
}
