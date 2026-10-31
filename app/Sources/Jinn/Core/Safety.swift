import Foundation

enum Safety {
    /// Apps Jinn must never drive: secret stores, the permission UI (self-grant), and terminals (bypass the shell classifier).
    static let blockedApps: Set<String> = [
        "com.apple.keychainaccess", "com.apple.securityagent", "com.apple.passwords", "com.apple.screensharingagent", "com.apple.usernotificationcenter", "com.apple.systempreferences", "com.apple.terminal", "com.googlecode.iterm2",
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.dhivio.jinn",
    ]

    static func checkApp(_ bundleID: String?) throws {
        if let b = bundleID?.lowercased(), blockedApps.contains(b) { throw JinnError.blocked("Jinn does not control \(b)") }
    }

    enum ShellVerdict: Equatable { case ok, block(String) }

    private static let dangerous: [(pattern: String, why: String)] = [
        (#"\bsudo\b|\bdoas\b"#, "privilege escalation"),
        (#"\brm\s+(-[a-z]*\s+)*-[a-z]*[rf][a-z]*\s+(-[a-z]*\s+)*(/|~|\$home|\*)(\s|$)"#, "recursive delete of a root, home or wildcard"),
        (#"\b(mkfs|fdisk|diskutil\s+(erase|partition|secure))"#, "disk formatting"),
        (#"\bdd\b[^|;]*\bof=/dev/"#, "raw disk write"),
        (#":\(\)\s*\{"#, "fork bomb"),
        (#"(curl|wget)[^|;]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#, "pipe from network into a shell"),
        (#"\b(chmod|chown)\s+-R\b[^;|]*\s/(\s|$)"#, "recursive permission change on /"),
        (#"\blaunchctl\s+(unload|bootout|remove)\b"#, "unloading system services"),
        (#"\b(shutdown|reboot|halt)\b"#, "power control"),
        (#"\.ssh|\.aws|\.gnupg|Keychains|\bsecurity\s+(find|dump|delete|export)"#, "credential store access"),
        (#"\b(nc|ncat|netcat)\b[^;|]*\s-[a-z]*e\b"#, "reverse shell"),
    ]

    static func shell(_ cmd: String) -> ShellVerdict {
        let v = ShellSafetyService.check(cmd, projectFolder: NSHomeDirectory()) // tokenized rm/find/chmod/fork-bomb checks, lifted from Agent!
        if !v.allowed { return .block(v.reason ?? "blocked") }
        for d in dangerous where cmd.range(of: d.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return .block(d.why)
        }
        return .ok
    }
}
