import Foundation

enum Trace {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Jinn/trace.jsonl")
    private static let lock = NSLock()

    static func log(tool: String, args: String, result: String, ms: Int) {
        let rec: [String: Any] = ["ts": ISO8601DateFormatter().string(from: Date()), "tool": tool, "args": args, "result": String(result.prefix(500)), "ms": ms]
        guard var line = try? JSONSerialization.data(withJSONObject: rec) else { return }
        line.append(10)
        lock.withLock {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(line); try? h.close() }
            else { try? line.write(to: file) }
        }
    }
}
