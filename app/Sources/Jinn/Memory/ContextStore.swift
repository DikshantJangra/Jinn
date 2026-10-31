import Foundation

private let seed = """
# Me
Name:
Email:
Phone:
Address:
Company:
Role:
Writing style: fast, direct, no filler
Preferences:
"""

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var d: Float = 0, x: Float = 0, y: Float = 0
    for i in a.indices { d += a[i] * b[i]; x += a[i] * a[i]; y += b[i] * b[i] }
    return x == 0 || y == 0 ? 0 : d / (x.squareRoot() * y.squareRoot())
}

func chunk(_ text: String, size: Int = 1500) -> [String] {
    var out: [String] = [], cur = ""
    for p in text.components(separatedBy: "\n\n") {
        if !cur.isEmpty, cur.count + p.count > size { out.append(cur); cur = "" }
        cur += (cur.isEmpty ? "" : "\n\n") + p
    }
    if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }
    return out
}

/// Everything Jinn knows about the user, kept small and relevant: me.md (always, capped), then the few chunks of the notes
/// folder and of connected files that match the question. Files are indexed incrementally (only changed ones are re-read),
/// and retrieval falls back to keyword matching when the embedding model is not available.
actor ContextStore {
    static let shared = ContextStore()
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jinn")
    static let notes = dir.appendingPathComponent("notes")
    static var meURL: URL {
        let u = dir.appendingPathComponent("me.md")
        try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: u.path) { try? seed.write(to: u, atomically: true, encoding: .utf8) }
        return u
    }
    /// Files outside the notes folder that the user connected (connect_file).
    static var sourcesURL: URL { dir.appendingPathComponent("sources.json") }
    static func sources() -> [String] { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: sourcesURL))) ?? [] }
    static func setSources(_ s: [String]) { try? JSONEncoder().encode(s).write(to: sourcesURL) }

    private struct Piece { let source: String; let text: String; let vec: [Float]? }
    private var cache: [String: (stamp: Date, pieces: [Piece])] = [:]

    func context(for query: String) async -> String {
        let me = String(((try? String(contentsOf: Self.meURL, encoding: .utf8)) ?? "").prefix(2500))
        var out = "About the user (private, local):\n" + me
        let hits = await retrieve(query)
        if !hits.isEmpty { out += "\n\nRelevant notes (from the user's files):\n" + hits.joined(separator: "\n---\n") }
        return out
    }

    private func files() -> [URL] {
        let notes = ((try? FileManager.default.contentsOfDirectory(at: Self.notes, includingPropertiesForKeys: nil)) ?? []).filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }
        return notes + Self.sources().map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Re-reads only files whose modification time changed; files removed or disconnected drop out.
    private func refresh(_ client: OllamaClient) async {
        var next: [String: (stamp: Date, pieces: [Piece])] = [:], embedDown = false
        for f in files() {
            let stamp = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil ?? .distantPast
            if let c = cache[f.path], c.stamp == stamp { next[f.path] = c; continue }
            var pieces: [Piece] = []
            for c in chunk(String(((try? String(contentsOf: f, encoding: .utf8)) ?? "").prefix(200_000))) {
                var v: [Float]?
                if !embedDown { v = try? await client.embed(c); if v == nil { embedDown = true } }
                pieces.append(Piece(source: f.lastPathComponent, text: c, vec: v))
            }
            next[f.path] = (stamp, pieces)
        }
        cache = next
    }

    private func retrieve(_ q: String, k: Int = 3, cap: Int = 3000) async -> [String] {
        let client = OllamaClient(model: "")
        await refresh(client)
        let all = cache.values.flatMap(\.pieces)
        guard !all.isEmpty else { return [] }
        let qv: [Float]? = all.contains { $0.vec != nil } ? try? await client.embed(q) : nil
        let words = Set(q.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 })
        let scored = all.map { p -> (Piece, Float) in
            if let qv, let v = p.vec { return (p, cosine(v, qv)) }
            let l = p.text.lowercased()
            return (p, words.isEmpty ? 0 : Float(words.filter { l.contains($0) }.count) / Float(words.count))
        }
        let floor: Float = qv != nil ? 0.4 : 0.34 // below this a chunk is noise and only burns context
        var out: [String] = [], used = 0
        for (p, s) in scored.sorted(by: { $0.1 > $1.1 }).prefix(k) where s >= floor {
            let t = "(\(p.source)) " + p.text
            if used + t.count > cap { break }
            used += t.count; out.append(t)
        }
        return out
    }
}

let connectFileTool = Tool(name: "connect_file", description: "Connect a text or markdown file to Jinn's memory: its content is then found automatically whenever it is relevant to a later question. Use when the user says remember this file, use this doc, or add this to what you know.",
                           params: ["path": "File path, ~ allowed"], risk: .confirm) { a in
    let p = try safePath(a.str("path")), name = (p as NSString).lastPathComponent
    guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { throw JinnError("only UTF-8 text or markdown files can be connected") }
    guard text.utf8.count <= 200_000 else { throw JinnError("\(name) is over 200 KB; connect a smaller file or split it") }
    var s = ContextStore.sources()
    guard !s.contains(p) else { return "\(name) is already connected." }
    s.append(p); ContextStore.setSources(s)
    Undo.shared.record("connected \(name)") { ContextStore.setSources(ContextStore.sources().filter { $0 != p }); return "disconnected it" }
    return "Connected \(name) (\(chunk(text).count) chunks). It will be used automatically when relevant."
}

let rememberTool = Tool(name: "remember", description: "Save a durable fact about the user (preference, detail, decision) to local notes for future turns",
                        params: ["fact": "The fact, one sentence"]) { a in
    let f = ContextStore.notes.appendingPathComponent("facts.md")
    _ = ContextStore.meURL
    let line = "\n\n" + (try a.str("fact"))
    let was = (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? UInt64) ?? nil
    Undo.shared.record("remembered a fact") {
        if let was { let h = try FileHandle(forWritingTo: f); defer { try? h.close() }; try h.truncate(atOffset: was) } else { try FileManager.default.removeItem(at: f) }
        return "forgot it"
    }
    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try line.trimmingCharacters(in: .whitespacesAndNewlines).write(to: f, atomically: true, encoding: .utf8) }
    return "Remembered."
}
