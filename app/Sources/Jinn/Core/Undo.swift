import AppKit

/// Journal of what Jinn did, newest last. Each entry knows how to reverse itself, or says it cannot.
/// Reversals only ever move things back or to the Trash; nothing is deleted for good.
final class Undo: @unchecked Sendable {
    static let shared = Undo()

    struct Entry { let label: String; let undo: (() async throws -> String)?; let at = Date() }
    private let lock = NSLock()
    private var stack: [Entry] = []

    /// `undo == nil` records an action that cannot be reversed (message sent, shell run), so "undo" says so
    /// instead of silently reverting something older.
    func record(_ label: String, undo: (() async throws -> String)? = nil) {
        lock.withLock { stack.append(Entry(label: label, undo: undo)); if stack.count > 50 { stack.removeFirst() } }
    }
    var count: Int { lock.withLock { stack.count } }
    func labels() -> [String] { lock.withLock { stack.reversed().map(\.label) } }
    private func pop() -> Entry? { lock.withLock { stack.popLast() } }

    /// Reverses the last `steps` actions, newest first. Stops at the first one that cannot be reversed.
    func undo(steps: Int = 1) async -> String {
        var done: [String] = []
        for _ in 0..<max(1, min(steps, 10)) {
            guard let e = pop() else { return done.isEmpty ? "Nothing to undo." : done.joined(separator: "\n") }
            guard let u = e.undo else { return (done + ["Cannot undo \"\(e.label)\": it has already left this Mac or cannot be reversed."]).joined(separator: "\n") }
            do { done.append("Undid \"\(e.label)\": \(try await u())") }
            catch { return (done + ["Could not undo \"\(e.label)\": \(explain(error))"]).joined(separator: "\n") }
        }
        return done.joined(separator: "\n")
    }
}

/// Where undo backups of overwritten files live.
let undoDir: URL = {
    let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jinn/undo")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()

/// Moves a path to the Trash and returns where it went.
@discardableResult
func trash(_ path: String) throws -> URL? {
    var out: NSURL?
    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &out)
    return out as URL?
}

/// Move `from` -> `to` (undo of a move/restore from Trash). Refuses to overwrite.
func moveBack(_ from: String, _ to: String) throws -> String {
    guard FileManager.default.fileExists(atPath: from) else { throw JinnError("\((from as NSString).lastPathComponent) is no longer there") }
    guard !FileManager.default.fileExists(atPath: to) else { throw JinnError("\((to as NSString).lastPathComponent) already exists at the original place") }
    try FileManager.default.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try FileManager.default.moveItem(atPath: from, toPath: to)
    return "moved back to \((to as NSString).abbreviatingWithTildeInPath)"
}

/// Actions that cannot be taken back once done, recorded centrally so "undo" is honest about them.
func irreversibleLabel(tool: String, args: [String: Any]) -> String? {
    switch tool {
    case "send_chat": return "message to \(args.opt("contact")) in \(args.opt("app"))"
    case "send_message": return "message to \(args.opt("to"))"
    case "reply_mail" where args.opt("send") == "true": return "mail reply to \(args.opt("find"))"
    case "run_shell": return "shell command \(args.opt("command").prefix(60))"
    case "web_fetch", "ping", "web_search": return nil
    default: return nil
    }
}

let undoTools: [Tool] = [
    Tool(name: "undo", description: "Take back what Jinn just did: move files back, restore overwritten files, put things back from the Trash, restore the clipboard or an edited field, reopen a quit app, undo typing, undo a Gmail send within seconds. Use when the user says undo, revert, take that back, or go back. Says clearly when something cannot be undone (sent messages, shell commands).",
         params: ["steps": "(optional) how many actions to undo, default 1", "list": "(optional) true to only list what can be undone"]) { a in
        if a.opt("list") == "true" { let l = Undo.shared.labels(); return l.isEmpty ? "Nothing to undo." : l.prefix(10).enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n") }
        return await Undo.shared.undo(steps: Int(a.opt("steps")) ?? 1)
    },
]
