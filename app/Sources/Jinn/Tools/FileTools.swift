import Foundation

let categories = [
    "Images": ["png", "jpg", "jpeg", "gif", "heic", "webp"],
    "Docs": ["pdf", "docx", "doc", "txt", "md", "pages", "xlsx", "csv", "pptx"],
    "Archives": ["zip", "dmg", "tar", "gz", "7z", "rar"],
    "Media": ["mp4", "mov", "mp3", "wav"],
]

func category(for ext: String) -> String? { categories.first { $0.value.contains(ext) }?.key }
func expand(_ p: String) -> String { (p as NSString).expandingTildeInPath }

private let allowedRoots = ["Downloads", "Documents", "Desktop"].map {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).resolvingSymlinksInPath().path.lowercased()
}
func safePath(_ p: String) throws -> String {
    let r = URL(fileURLWithPath: expand(p)).resolvingSymlinksInPath().standardized.path
    let l = r.lowercased()
    guard allowedRoots.contains(where: { l == $0 || l.hasPrefix($0 + "/") }) else { throw JinnError("\(p) is outside Downloads, Documents and Desktop") }
    return r
}

func organize(_ dir: URL) throws -> Int {
    let fm = FileManager.default
    var moved = 0
    for f in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) {
        guard let cat = category(for: f.pathExtension.lowercased()) else { continue }
        let sub = dir.appendingPathComponent(cat)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let dest = sub.appendingPathComponent(f.lastPathComponent)
        guard !fm.fileExists(atPath: dest.path) else { continue }
        try fm.moveItem(at: f, to: dest)
        moved += 1
    }
    return moved
}

let fileTools: [Tool] = [
    Tool(name: "organize_downloads", description: "Sort loose files in ~/Downloads into subfolders (Images, Docs, Archives, Media) by file type", risk: .confirm) { _ in
        let n = try organize(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
        return "Moved \(n) files into category folders."
    },
    Tool(name: "list_dir", description: "List the files in a folder", params: ["path": "Folder path, ~ allowed"]) { a in
        try FileManager.default.contentsOfDirectory(atPath: try safePath(a.str("path"))).sorted().prefix(200).joined(separator: "\n")
    },
    Tool(name: "read_file", description: "Read a text file (first 8000 characters)", params: ["path": "File path, ~ allowed"]) { a in
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: try safePath(a.str("path"))))
        defer { try? h.close() }
        let data = try h.read(upToCount: 65536) ?? Data()
        guard let s = (0...3).lazy.compactMap({ String(data: data.dropLast($0), encoding: .utf8) }).first else { throw JinnError("not a UTF-8 text file") }
        return String(s.prefix(8000))
    },
    Tool(name: "move_file", description: "Move or rename a file or folder. Fails if the destination exists.",
         params: ["from": "Source path", "to": "Destination path"], risk: .confirm) { a in
        let to = URL(fileURLWithPath: try safePath(a.str("to")))
        try vetWrite(to.path)
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: try safePath(a.str("from")), toPath: to.path)
        return "Moved."
    },
]
