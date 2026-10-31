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

/// Paragraph-packed chunks of roughly `size` characters.
func chunk(_ text: String, size: Int = 1500) -> [String] {
    var out: [String] = [], cur = ""
    for p in text.components(separatedBy: "\n\n") {
        if !cur.isEmpty, cur.count + p.count > size { out.append(cur); cur = "" }
        cur += (cur.isEmpty ? "" : "\n\n") + p
    }
    if !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(cur) }
    return out
}

/// me.md is always in the prompt; notes/*.md are retrieved by embedding similarity (Ollama nomic-embed-text, all local).
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

    // ponytail: in-memory index rebuilt when note mtimes change; persist to disk if notes get large
    private var index: [(text: String, vec: [Float])] = []
    private var signature = ""

    func context(for query: String) async -> String {
        let me = (try? String(contentsOf: Self.meURL, encoding: .utf8)) ?? ""
        var out = "About the user (private, local):\n" + me
        let hits = await retrieve(query)
        if !hits.isEmpty { out += "\n\nRelevant notes:\n" + hits.joined(separator: "\n---\n") }
        return out
    }

    private func retrieve(_ q: String, k: Int = 3) async -> [String] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: Self.notes, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "md" }
        let sig = files.map { "\($0.lastPathComponent)\((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)" }.joined()
        let client = OllamaClient(model: "")
        if sig != signature {
            index = []
            for f in files {
                for c in chunk((try? String(contentsOf: f, encoding: .utf8)) ?? "") {
                    guard let v = try? await client.embed(c) else { return [] } // embed model missing: skip retrieval silently
                    index.append((c, v))
                }
            }
            signature = sig
        }
        guard !index.isEmpty, let qv = try? await client.embed(q) else { return [] }
        return index.sorted { cosine($0.vec, qv) > cosine($1.vec, qv) }.prefix(k).map(\.text)
    }
}

let rememberTool = Tool(name: "remember", description: "Save a durable fact about the user (preference, detail, decision) to local notes for future turns",
                        params: ["fact": "The fact, one sentence"]) { a in
    let f = ContextStore.notes.appendingPathComponent("facts.md")
    _ = ContextStore.meURL // ensures dirs exist
    let line = "\n\n" + (try a.str("fact"))
    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try line.trimmingCharacters(in: .whitespacesAndNewlines).write(to: f, atomically: true, encoding: .utf8) }
    return "Remembered."
}
