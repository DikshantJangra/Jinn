import AppKit

/// Media, audio, radios, appearance and power: each a direct system call, no UI driving.
enum Mac {
    // MARK: music (Music app library, then any audio file Spotlight finds)

    static func music(_ verb: String) throws -> String {
        _ = try AppleScript.run("tell application \"Music\" to \(verb)")
        return verb == "pause" ? "Paused." : nowPlaying()
    }

    static func nowPlaying() -> String {
        let r = (try? AppleScript.run("tell application \"Music\" to if player state is playing then return (name of current track) & \" by \" & (artist of current track)")) ?? ""
        return r.isEmpty ? "Done." : "Playing \(r)."
    }

    static func play(_ q: String) async throws -> String {
        if q.isEmpty { return try music("play") }
        let e = AppleScript.esc(q)
        let hit = try AppleScript.run("""
        tell application "Music"
            set hits to (every track of library playlist 1 whose name contains "\(e)" or artist contains "\(e)" or album contains "\(e)")
            if hits is {} then return ""
            play item 1 of hits
            return (name of current track) & " by " & (artist of current track)
        end tell
        """)
        if !hit.isEmpty { return "Playing \(hit)." }
        let safe = q.replacingOccurrences(of: #"["'*\\]"#, with: "", options: .regularExpression)
        let found = try Shell.run("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), "kMDItemContentTypeTree == 'public.audio' && kMDItemFSName == '*\(safe)*'cd"])
        guard let path = found.split(separator: "\n").first else { throw JinnError("no song, artist or album matching \"\(q)\" in the Music library or your audio files") }
        NSWorkspace.shared.open(URL(fileURLWithPath: String(path)))
        return "Playing \((path as NSString).lastPathComponent)."
    }

    // MARK: volume

    static func volume(_ v: String) throws -> String {
        let cur = Int(try AppleScript.run("output volume of (get volume settings)")) ?? 50
        let to = v == "up" ? cur + 15 : v == "down" ? cur - 15 : Int(v) ?? -1
        guard to >= -15 else { throw JinnError("volume needs up, down or 0-100") }
        let n = max(0, min(100, to))
        _ = try AppleScript.run("set volume output volume \(n) without output muted")
        return "Volume \(n)%."
    }

    static func mute(_ on: Bool) throws -> String {
        _ = try AppleScript.run("set volume \(on ? "with" : "without") output muted")
        return on ? "Muted." : "Unmuted."
    }

    // MARK: radios

    /// The switch blueutil uses; IOBluetooth exports it but no header declares it.
    private static let bt = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)

    static func bluetooth(_ want: String) async throws -> String {
        guard let g = dlsym(bt, "IOBluetoothPreferenceGetControllerPowerState"), let s = dlsym(bt, "IOBluetoothPreferenceSetControllerPowerState")
        else { throw JinnError("this macOS does not expose the Bluetooth switch") }
        let get = unsafeBitCast(g, to: (@convention(c) () -> Int32).self), set = unsafeBitCast(s, to: (@convention(c) (Int32) -> Void).self)
        let on = try state(want, now: get() != 0)
        set(on ? 1 : 0)
        for _ in 0..<30 { // the controller switches asynchronously
            if (get() != 0) == on { return "Bluetooth is \(on ? "on" : "off")." }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw JinnError("Bluetooth did not turn \(on ? "on" : "off")")
    }

    static func wifi(_ want: String) throws -> String {
        let ports = try Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        guard let r = ports.range(of: #"Wi-Fi\nDevice: (\w+)"#, options: .regularExpression) else { throw JinnError("no Wi-Fi hardware found") }
        let dev = String(ports[r].split(separator: " ").last!)
        let on = try state(want, now: try Shell.run("/usr/sbin/networksetup", ["-getairportpower", dev]).hasSuffix("On"))
        _ = try Shell.run("/usr/sbin/networksetup", ["-setairportpower", dev, on ? "on" : "off"])
        return "Wi-Fi is \(on ? "on" : "off")."
    }

    private static func state(_ want: String, now: Bool) throws -> Bool {
        switch want.lowercased() {
        case "on": return true
        case "off": return false
        case "", "toggle": return !now
        default: throw JinnError("value must be on, off or toggle")
        }
    }

    // MARK: appearance and power

    static func darkMode(_ want: String) throws -> String {
        let now = try AppleScript.run("tell application \"System Events\" to tell appearance preferences to return dark mode") == "true"
        let on = try state(want, now: now)
        _ = try AppleScript.run("tell application \"System Events\" to tell appearance preferences to set dark mode to \(on)")
        return "Dark mode \(on ? "on" : "off")."
    }

    static func lock() throws -> String {
        let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
        if let f = dlsym(login, "SACLockScreenImmediate") { unsafeBitCast(f, to: (@convention(c) () -> Int32).self)(); return "Locked." }
        _ = try Shell.run("/usr/bin/pmset", ["displaysleepnow"]) // locks when "require password" is immediate
        return "Screen off."
    }

    /// Sleep returns before the Mac sleeps, so the reply still reaches the HUD.
    static func power(_ action: String) throws -> String {
        switch action {
        case "sleep": _ = try Shell.run("/usr/bin/pmset", ["sleepnow"]); return "Sleeping."
        case "display_off": _ = try Shell.run("/usr/bin/pmset", ["displaysleepnow"]); return "Display off."
        case "shutdown": _ = try AppleScript.run("tell application \"System Events\" to shut down"); return "Shutting down."
        case "restart": _ = try AppleScript.run("tell application \"System Events\" to restart"); return "Restarting."
        default: _ = try AppleScript.run("tell application \"System Events\" to log out"); return "Logging out."
        }
    }
}
