import AppKit

enum Apps {
    static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    /// Match by exact name, bundle id, then substring. Blocked apps are refused here, once, for every Hands caller.
    static func resolve(_ name: String) throws -> NSRunningApplication {
        let l = name.lowercased()
        guard l.count >= 2 else { throw JinnError("app name required (at least 2 characters)") }
        let apps = running()
        guard let a = apps.first(where: { $0.localizedName?.lowercased() == l || $0.bundleIdentifier?.lowercased() == l })
                ?? apps.first(where: { $0.localizedName?.lowercased().contains(l) == true })
        else { throw JinnError("app not running: \(name) (use open_app first, or list_apps)") }
        try Safety.checkApp(a.bundleIdentifier)
        return a
    }

    static func list() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return running().compactMap { a in
            guard let n = a.localizedName, !(Safety.blockedApps.contains(a.bundleIdentifier?.lowercased() ?? "")) else { return nil }
            return "\(n) (\(a.bundleIdentifier ?? "?"))" + (a.processIdentifier == front ? " [frontmost]" : "")
        }.joined(separator: "\n")
    }
}
