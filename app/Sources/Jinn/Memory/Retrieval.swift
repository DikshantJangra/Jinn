import Foundation

// Pure retrieval helpers (no I/O) so they can be checked by --selftest.

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

/// Splits a markdown file on headings first so a chunk never straddles two topics, then packs paragraphs up to `size`.
func chunkMarkdown(_ text: String, size: Int = 900) -> [String] {
    var sections: [String] = [], cur: [String] = []
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("#"), !cur.isEmpty { sections.append(cur.joined(separator: "\n")); cur = [] }
        cur.append(line)
    }
    sections.append(cur.joined(separator: "\n"))
    return sections.flatMap { chunk($0.trimmingCharacters(in: .whitespacesAndNewlines), size: size) }.filter { !$0.isEmpty }
}

private let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are", "was", "my", "me", "i", "you", "your", "what", "which", "who", "do", "does", "it", "this", "that", "with", "at", "by", "be", "as", "please"]
/// Words that mean the same field in forms and in a profile: both sides are folded to one token.
private let alias: [String: String] = ["mail": "email", "e-mail": "email", "mobile": "phone", "telephone": "phone", "tel": "phone", "cell": "phone", "whatsapp": "phone", "contact": "phone",
                                       "fullname": "name", "surname": "name", "organisation": "company", "organization": "company", "employer": "company", "job": "role", "title": "role", "designation": "role",
                                       "location": "address", "city": "address", "residence": "address", "street": "address"]

/// Lowercase word tokens with stopwords dropped, a crude plural strip and form/profile synonyms folded together.
func tokens(_ s: String) -> [String] {
    s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).compactMap { w in
        var t = String(w)
        if t.count > 3, t.hasSuffix("s"), !t.hasSuffix("ss") { t.removeLast() }
        t = alias[t] ?? t
        return t.count < 2 || stop.contains(t) ? nil : t
    }
}

/// Okapi BM25 over a small in-memory corpus. Returns one score per document; 0 means no query term matched.
func bm25(query: [String], docs: [[String]], k1: Double = 1.4, b: Double = 0.75) -> [Double] {
    guard !docs.isEmpty else { return [] }
    let avg = max(1, Double(docs.reduce(0) { $0 + $1.count }) / Double(docs.count))
    var df: [String: Int] = [:]
    for d in docs { for t in Set(d) { df[t, default: 0] += 1 } }
    let n = Double(docs.count)
    return docs.map { d in
        var tf: [String: Int] = [:]
        for t in d { tf[t, default: 0] += 1 }
        return Set(query).reduce(0.0) { s, t in
            guard let f = tf[t].map(Double.init), let c = df[t] else { return s }
            let idf = log(1 + (n - Double(c) + 0.5) / (Double(c) + 0.5))
            return s + idf * f * (k1 + 1) / (f + k1 * (1 - b + b * Double(d.count) / avg))
        }
    }
}

/// Reciprocal Rank Fusion: merges ranked lists by position, so BM25 and cosine scores never need the same scale.
func rrf(_ rankings: [[Int]], k: Double = 60) -> [Int: Double] {
    var out: [Int: Double] = [:]
    for r in rankings { for (pos, id) in r.enumerated() { out[id, default: 0] += 1 / (k + Double(pos + 1)) } }
    return out
}

/// Stable across launches (Swift's String.hashValue is seeded per process), so the on-disk index can be reused.
func stableHash(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return String(h, radix: 16)
}

/// Words that mean it is not safe to store the line as a "fact".
private let secretPattern = try! NSRegularExpression(pattern: "(password|passcode|passwd|\\botp\\b|\\bpin\\b|cvv|\\bssn\\b|api[ _-]?key|secret|token|private key|\\b\\d{12,19}\\b)", options: .caseInsensitive)
func looksSecret(_ s: String) -> Bool { secretPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

/// True when the user's own message states something about themself worth keeping.
private let selfPattern = try! NSRegularExpression(pattern: "\\b(my|i am|i'm|i live|i work|i prefer|i like|i love|i hate|i use|i usually|i always|i never|call me|remember|from now on|don't ever|do not ever)\\b", options: .caseInsensitive)
func mentionsSelf(_ s: String) -> Bool { selfPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }

/// Token overlap (Jaccard) used to skip a fact that is already stored in other words.
func similarFact(_ a: String, _ b: String) -> Bool {
    let x = Set(tokens(a)), y = Set(tokens(b))
    guard !x.isEmpty, !y.isEmpty else { return false }
    return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.7
}
