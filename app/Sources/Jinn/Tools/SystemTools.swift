import AppKit

private let runnable: Set<String> = ["app", "command", "sh", "zsh", "bash", "terminal", "pkg", "mpkg", "dmg", "scpt", "scptd", "workflow", "action", "jar", "tool", "webloc", "url",
                                     "fileloc", "inetloc", "prefpane", "shortcut", "plist", "py", "rb", "pl", "php", "js", "command", "service", "saver", "kext", "dylib", "so"]
private let documents: Set<String> = ["txt", "md", "pdf", "doc", "docx", "pages", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key", "rtf", "json", "xml", "yaml", "yml", "toml",
                                      "html", "htm", "css", "log", "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "mp3", "mp4", "mov", "wav", "m4a", "zip"]
private let sourceCode: Set<String> = ["py", "js", "ts", "tsx", "jsx", "swift", "go", "rs", "java", "c", "h", "cpp", "rb", "php", "sql", "sh", "plist"]
private let deniedApps = ["terminal", "iterm", "script editor", "automator", "python launcher", "shortcuts", "xcode"]

func vetWrite(_ path: String) throws {
    let ext = (path as NSString).pathExtension.lowercased()
    if runnable.contains(ext) && !sourceCode.contains(ext) { throw JinnError.blocked(".\(ext) files can run code; will not create one") }
    if (path as NSString).lastPathComponent.hasPrefix(".") { throw JinnError.blocked("will not write dotfiles") }
}

let systemTools: [Tool] = [
    Tool(name: "find_files", description: "Find files or folders by name anywhere in Downloads, Documents and Desktop (Spotlight). Use this to locate a file before open_file, read_file or move_file.",
         params: ["name": "Part of the file name, e.g. AGENTS.md or invoice", "folder": "(optional) limit to this folder"]) { a in
        let roots = a.opt("folder").isEmpty ? ["Downloads", "Documents", "Desktop"].map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path }
                                            : [try safePath(a.opt("folder"))]
        var hits: [String] = []
        for r in roots {
            let out = (try? Shell.run("/usr/bin/mdfind", ["-onlyin", r, "-name", try a.str("name")], timeout: 15)) ?? ""
            hits += out.split(separator: "\n").map(String.init).filter { (try? safePath($0)) != nil }
        }
        let unique = Array(Set(hits)).sorted { $0.count < $1.count }.prefix(30)
        return unique.isEmpty ? "No file matching \"\(a.opt("name"))\" found." : unique.joined(separator: "\n")
    },

    Tool(name: "open_file", description: "Open a file or folder like double-clicking it: in its default app, or in a specific app. Opening a folder shows it in Finder. Use find_files first if you do not know the path. Never ask the user to open files themselves; call this.",
         params: ["path": "File or folder path, ~ allowed", "app": "(optional) app to open it with, e.g. TextEdit, Visual Studio Code"], risk: .confirm) { a in
        let path = try safePath(a.str("path"))
        guard FileManager.default.fileExists(atPath: path) else { throw JinnError("\(path) does not exist; try find_files") }
        let ext = (path as NSString).pathExtension.lowercased()
        let app = a.opt("app")
        if app.hasPrefix("-") || deniedApps.contains(where: app.lowercased().contains) { throw JinnError.blocked("that app can run code; pick an editor") }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let ok = isDir.boolValue ? !runnable.contains(ext) : documents.contains(ext) || (sourceCode.contains(ext) && !app.isEmpty)
        if !ok { throw JinnError.blocked(".\(ext.isEmpty ? "(no extension)" : ext) files are not opened automatically" + (sourceCode.contains(ext) ? "; name an editor in app" : "; ask the user to open it")) }
        _ = try Shell.run("/usr/bin/open", app.isEmpty ? [path] : ["-a", app, path])
        return "Opened \((path as NSString).lastPathComponent)" + (app.isEmpty ? "." : " in \(app).")
    },

    Tool(name: "reveal_in_finder", description: "Show a file selected in a Finder window.", params: ["path": "File or folder path, ~ allowed"]) { a in
        _ = try Shell.run("/usr/bin/open", ["-R", try safePath(a.str("path"))])
        return "Revealed in Finder."
    },

    Tool(name: "write_file", description: "Create a text file, or append to one. Will not overwrite an existing file unless overwrite is true.",
         params: ["path": "File path, ~ allowed", "text": "Content", "mode": "(optional) create (default), append or overwrite"], risk: .confirm) { a in
        let path = try safePath(a.str("path")), text = try a.str("text"), mode = a.opt("mode")
        let url = URL(fileURLWithPath: path), fm = FileManager.default, st = Stamp()
        try vetWrite(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: path) {
            if mode == "append" {
                let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
                let was = try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); try h.synchronize()
                st.v = stamp(path)
                Undo.shared.record("appended to \(url.lastPathComponent)") { try requireUnchanged(path, st); let w = try FileHandle(forWritingTo: url); defer { try? w.close() }; try w.truncate(atOffset: was); return "removed the appended text" }
                return "Appended to \(url.lastPathComponent)."
            }
            guard mode == "overwrite" else { throw JinnError("\(url.lastPathComponent) exists; use mode append or overwrite") }
            let backup = undoDir.appendingPathComponent(UUID().uuidString)
            try fm.copyItem(at: url, to: backup)
            Undo.shared.record("overwrote \(url.lastPathComponent)") { try requireUnchanged(path, st); try Data(contentsOf: backup).write(to: url); return "restored the previous content" }
        } else {
            Undo.shared.record("created \(url.lastPathComponent)") { try requireUnchanged(path, st); try trash(path); return "moved it to the Trash" }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        st.v = stamp(path)
        return "Wrote \(url.lastPathComponent) (\(text.count) characters)."
    },

    Tool(name: "make_folder", description: "Create a folder (and parents).", params: ["path": "Folder path, ~ allowed"], risk: .confirm) { a in
        let p = try safePath(a.str("path"))
        let existed = FileManager.default.fileExists(atPath: p)
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        if !existed {
            Undo.shared.record("created folder \((p as NSString).lastPathComponent)") {
                guard (try FileManager.default.contentsOfDirectory(atPath: p).filter { $0 != ".DS_Store" }).isEmpty else { throw JinnError("the folder has files in it now, so undo would remove them from view") }
                try trash(p); return "moved it to the Trash"
            }
        }
        return "Created."
    },

    Tool(name: "copy_file", description: "Copy a file or folder. Fails if the destination exists.", params: ["from": "Source path", "to": "Destination path"], risk: .confirm) { a in
        let to = URL(fileURLWithPath: try safePath(a.str("to")))
        try vetWrite(to.path)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: try safePath(a.str("from")), toPath: to.path)
        let st = Stamp(); st.v = stamp(to.path)
        Undo.shared.record("copied to \(to.lastPathComponent)") { try requireUnchanged(to.path, st); try trash(to.path); return "moved the copy to the Trash" }
        return "Copied."
    },

    Tool(name: "trash_file", description: "Move a file or folder to the Trash (recoverable). Never deletes permanently.", params: ["path": "File or folder path, ~ allowed"], risk: .confirm, alwaysAsk: true) { a in
        let p = try safePath(a.str("path"))
        let gone = try trash(p)
        Undo.shared.record("trashed \((p as NSString).lastPathComponent)", undo: gone.map { g in { try moveBack(g.path, p) } })
        return "Moved to Trash."
    },

    Tool(name: "clipboard_get", description: "Read the text currently on the clipboard.", risk: .confirm) { _ in
        String((NSPasteboard.general.string(forType: .string) ?? "(clipboard has no text)").prefix(4000))
    },

    Tool(name: "clipboard_set", description: "Put text on the clipboard so the user (or paste via press_key cmd+v) can use it.", params: ["text": "Text to copy"], risk: .confirm) { a in
        let was = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(try a.str("text"), forType: .string)
        Undo.shared.record("set the clipboard") { NSPasteboard.general.clearContents(); if let was { NSPasteboard.general.setString(was, forType: .string) }; return "restored the old clipboard" }
        return "Copied to clipboard."
    },

    Tool(name: "open_settings", description: "Open a System Settings privacy/other pane by keyword, e.g. Accessibility, Microphone, Screen Recording.", params: ["pane": "Pane name"]) { a in
        let map = ["accessibility": "Accessibility", "microphone": "Microphone", "screen recording": "ScreenCapture", "automation": "Automation", "files": "FilesAndFolders", "full disk access": "AllFiles"]
        guard let p = map[try a.str("pane").lowercased()] else { throw JinnError("known panes: \(map.keys.sorted().joined(separator: ", "))") }
        Permissions.openSettings(p)
        return "Opened the \(p) pane."
    },

    Tool(name: "mac_control", description: "Control the Mac directly. action: play (value = song, artist or album from local music; empty resumes), pause, next, previous, volume (value = 0-100, up or down), mute, unmute, bluetooth / wifi / dark_mode (value = on, off or toggle), sleep, display_off, lock, shutdown, restart, logout.",
         params: ["action": "One of the actions above", "value": "(optional) see action"],
         askIf: { ["shutdown", "restart", "logout"].contains($0.opt("action").lowercased()) }) { a in
        let v = a.opt("value")
        switch try a.str("action").lowercased() {
        case "play": return try await Mac.play(v)
        case "pause": return try Mac.music("pause")
        case "next": return try Mac.music("next track")
        case "previous": return try Mac.music("previous track")
        case "volume": return try Mac.volume(v.lowercased())
        case "mute": return try Mac.mute(true)
        case "unmute": return try Mac.mute(false)
        case "bluetooth": return try await Mac.bluetooth(v)
        case "wifi": return try Mac.wifi(v)
        case "dark_mode": return try Mac.darkMode(v)
        case "lock": return try Mac.lock()
        case let p where ["sleep", "display_off", "shutdown", "restart", "logout"].contains(p): return try Mac.power(p)
        case let x: throw JinnError("unknown action \(x)")
        }
    },
]

/// Plain switch commands ("bluetooth off", "next song", "sleep") skip the model entirely: mac_control args, or nil to let the model handle it.
func quickControl(_ text: String) -> [String: Any]? {
    let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        .replacingOccurrences(of: #"^(hey |ok )?(jinn,? )?(please |can you |could you )?|\s+please$"#, with: "", options: .regularExpression)
    func m(_ p: String) -> [String]? {
        guard let r = try? NSRegularExpression(pattern: p), let h = r.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        return (1..<h.numberOfRanges).map { h.range(at: $0).location == NSNotFound ? "" : String(t[Range(h.range(at: $0), in: t)!]) }
    }
    let radio = { (s: String) in s.hasPrefix("blue") ? "bluetooth" : s.hasPrefix("dark") ? "dark_mode" : "wifi" }
    if let g = m(#"^(?:turn |switch )?(bluetooth|wi-?fi|dark mode) (on|off)$"#) { return ["action": radio(g[0]), "value": g[1]] }
    if let g = m(#"^(?:turn |switch )(on|off) (?:the )?(bluetooth|wi-?fi|dark mode)$"#) { return ["action": radio(g[1]), "value": g[0]] }
    if let g = m(#"^(?:set )?(?:the )?volume (?:to )?(up|down|\d{1,3})%?$"#) { return ["action": "volume", "value": g[0]] }
    if let g = m(#"^play (?!.*\b(?:youtube|spotify|chrome|browser|video|on)\b)(.+)$"#) { return ["action": "play", "value": g[0]] }
    let fixed: [(String, String)] = [
        (#"^(?:pause|stop)(?: the)?(?: music| song| playback)?$"#, "pause"), (#"^(?:play|resume)(?: the)?(?: music| song)?$"#, "play"),
        (#"^(?:next|skip)(?: the)?(?: song| track)?$"#, "next"), (#"^(?:previous|prev|last)(?: song| track)?$"#, "previous"),
        (#"^mute$"#, "mute"), (#"^unmute$"#, "unmute"),
        (#"^(?:go to )?sleep(?: (?:the )?(?:mac|computer))?$"#, "sleep"), (#"^(?:turn off|switch off) (?:the )?(?:display|screen)$"#, "display_off"),
        (#"^lock(?: (?:the )?(?:mac|computer|screen))?$"#, "lock"),
        (#"^(?:shut ?down|power off)(?: (?:the )?(?:mac|computer))?$|^turn off (?:the )?(?:mac|computer)$"#, "shutdown"),
        (#"^(?:restart|reboot)(?: (?:the )?(?:mac|computer))?$"#, "restart"), (#"^log ?out$"#, "logout"),
    ]
    return fixed.first { m($0.0) != nil }.map { ["action": $0.1] }
}
