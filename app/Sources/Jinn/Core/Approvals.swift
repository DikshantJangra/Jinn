import Foundation

/// once = this call only; session = until Jinn quits; always = persisted (offered for apps only).
enum Decision { case deny, once, session, always }
struct ConfirmRequest { let tool: String; let summary: String; let scope: String; let persist: Bool; let session: Bool }

/// Grants keyed by scope: an app's bundle id, or "tool:<name>" for tools that are not tied to an app.
final class Approvals {
    static let shared = Approvals(file: ContextStore.dir.appendingPathComponent("approvals.json"))
    private let file: URL?
    private var session = Set<String>()
    private var stored: Set<String>
    private let lock = NSLock()

    init(file: URL?) {
        self.file = file
        stored = Set(file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    func allowed(_ scope: String) -> Bool { lock.withLock { session.contains(scope) || stored.contains(scope) } }

    func grant(_ scope: String, always: Bool) {
        lock.withLock {
            session.insert(scope)
            guard always, let file else { return }
            stored.insert(scope)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(stored.sorted()).write(to: file)
        }
    }
}
