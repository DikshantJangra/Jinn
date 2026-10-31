import AppKit

enum Apps {
    static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

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

    static func target(_ name: String) throws -> NSRunningApplication {
        if !name.isEmpty { return try resolve(name) }
        guard let a = NSWorkspace.shared.frontmostApplication, a.bundleIdentifier != Bundle.main.bundleIdentifier else { throw JinnError("no app in front; name one") }
        try Safety.checkApp(a.bundleIdentifier)
        return a
    }

    static func launch(_ name: String, background: Bool = false) throws {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n.count >= 2, !n.contains("/"), !n.hasPrefix("-"), !n.lowercased().hasSuffix(".app") else { throw JinnError("give the app's name, like WhatsApp") }
        guard let path = NSWorkspace.shared.fullPath(forApplication: n) else { throw JinnError("no installed app named \(n)") }
        try Safety.checkApp(Bundle(path: path)?.bundleIdentifier)
        _ = try Shell.run("/usr/bin/open", (background ? ["-g"] : []) + [path])
    }

    static func list() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return running().compactMap { a in
            guard let n = a.localizedName, !(Safety.blockedApps.contains(a.bundleIdentifier?.lowercased() ?? "")) else { return nil }
            return "\(n) (\(a.bundleIdentifier ?? "?"))" + (a.processIdentifier == front ? " [frontmost]" : "")
        }.joined(separator: "\n")
    }
}
