import AppKit

enum Shell {
    /// A hung target app (osascript waits on it) must not stall the agent forever.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 60) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let out = o.fileHandleForReading.readDataToEndOfFile()
        let err = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        if p.terminationReason == .uncaughtSignal { throw JinnError("\(exe) timed out after \(Int(timeout))s") }
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw JinnError(msg.isEmpty ? "\(exe) exited \(p.terminationStatus)" : msg + " (if blocked, grant Automation in System Settings > Privacy & Security)")
        }
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Shell {
    /// Runs a zsh command line from $HOME with a timeout; stdout+stderr merged, capped. Callers must vet the command (Safety.shell).
    static func sh(_ cmd: String, timeout: TimeInterval = 30) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let o = Pipe()
        p.standardOutput = o; p.standardError = o
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return "exit \(p.terminationStatus)\n" + String(decoding: data.prefix(8000), as: UTF8.self)
    }
}

enum AppleScript {
    @discardableResult
    static func run(_ source: String) throws -> String { try Shell.run("/usr/bin/osascript", ["-e", source]) }
    static func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
}
