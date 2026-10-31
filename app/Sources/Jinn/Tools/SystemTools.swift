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
        let url = URL(fileURLWithPath: path), fm = FileManager.default
        try vetWrite(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: path) {
            if mode == "append" {
                let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
                try h.seekToEnd(); try h.write(contentsOf: Data(text.utf8)); return "Appended to \(url.lastPathComponent)."
            }
            guard mode == "overwrite" else { throw JinnError("\(url.lastPathComponent) exists; use mode append or overwrite") }
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(url.lastPathComponent) (\(text.count) characters)."
    },

    Tool(name: "make_folder", description: "Create a folder (and parents).", params: ["path": "Folder path, ~ allowed"], risk: .confirm) { a in
        try FileManager.default.createDirectory(atPath: try safePath(a.str("path")), withIntermediateDirectories: true)
        return "Created."
    },

    Tool(name: "copy_file", description: "Copy a file or folder. Fails if the destination exists.", params: ["from": "Source path", "to": "Destination path"], risk: .confirm) { a in
        let to = URL(fileURLWithPath: try safePath(a.str("to")))
        try vetWrite(to.path)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: try safePath(a.str("from")), toPath: to.path)
        return "Copied."
    },

    Tool(name: "trash_file", description: "Move a file or folder to the Trash (recoverable). Never deletes permanently.", params: ["path": "File or folder path, ~ allowed"], risk: .confirm, alwaysAsk: true) { a in
        try FileManager.default.trashItem(at: URL(fileURLWithPath: try safePath(a.str("path"))), resultingItemURL: nil)
        return "Moved to Trash."
    },

    Tool(name: "clipboard_get", description: "Read the text currently on the clipboard.", risk: .confirm) { _ in
        String((NSPasteboard.general.string(forType: .string) ?? "(clipboard has no text)").prefix(4000))
    },

    Tool(name: "clipboard_set", description: "Put text on the clipboard so the user (or paste via press_key cmd+v) can use it.", params: ["text": "Text to copy"], risk: .confirm) { a in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(try a.str("text"), forType: .string)
        return "Copied to clipboard."
    },

    Tool(name: "open_settings", description: "Open a System Settings privacy/other pane by keyword, e.g. Accessibility, Microphone, Screen Recording.", params: ["pane": "Pane name"]) { a in
        let map = ["accessibility": "Accessibility", "microphone": "Microphone", "screen recording": "ScreenCapture", "automation": "Automation", "files": "FilesAndFolders", "full disk access": "AllFiles"]
        guard let p = map[try a.str("pane").lowercased()] else { throw JinnError("known panes: \(map.keys.sorted().joined(separator: ", "))") }
        Permissions.openSettings(p)
        return "Opened the \(p) pane."
    },
]
