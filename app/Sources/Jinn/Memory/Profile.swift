import Foundation

// me.md is plain markdown the user can edit by hand: `Key: value` lines at the top, then free `## sections`.
// Jinn itself only ever touches two things: a field's value, and bullets under `## Learned`.

let profileSeed = """
# Me
Name:
Email:
Phone:
Address:
Company:
Role:
Writing style: fast, direct, no filler
Preferences:

## Learned
"""

private let learnedHeading = "## Learned"
private let fieldPattern = try! NSRegularExpression(pattern: "^([A-Za-z][A-Za-z0-9 /_-]{0,30}):[ \\t]*(.*)$")

private func lines(_ text: String) -> [String] { text.components(separatedBy: "\n") }
private func headIndex(_ ls: [String]) -> Int { ls.firstIndex { $0.hasPrefix("## ") } ?? ls.count }

private func field(_ line: String) -> (key: String, value: String)? {
    let r = NSRange(line.startIndex..., in: line)
    guard let m = fieldPattern.firstMatch(in: line, range: r), let k = Range(m.range(at: 1), in: line), let v = Range(m.range(at: 2), in: line) else { return nil }
    return (String(line[k]), String(line[v]).trimmingCharacters(in: .whitespaces))
}

/// `Key: value` lines before the first `##` section. Empty values are kept (they mean "not set yet").
func profileFields(_ text: String) -> [(key: String, value: String)] {
    let ls = lines(text)
    return ls[..<headIndex(ls)].compactMap(field)
}

/// Bullets under `## Learned`, oldest first.
func learnedFacts(_ text: String) -> [String] {
    let ls = lines(text)
    guard let h = ls.firstIndex(of: learnedHeading) else { return [] }
    return ls[(h + 1)...].prefix { !$0.hasPrefix("## ") }
        .compactMap { $0.hasPrefix("- ") ? String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) : nil }.filter { !$0.isEmpty }
}

/// Sets `key` (matched case-insensitively) to `value`, adding the line above the first section when it does not exist.
func settingField(in text: String, key: String, value: String) -> String {
    var ls = lines(text)
    let k = key.trimmingCharacters(in: .whitespaces)
    let end = headIndex(ls)
    let line = "\(k): \(value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces))"
    if let i = ls[..<end].firstIndex(where: { field($0)?.key.lowercased() == k.lowercased() }) {
        ls[i] = "\(field(ls[i])!.key): \(line.dropFirst(k.count + 2))"
    } else {
        var at = end
        while at > 0, ls[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 } // keep the blank line before the next section
        ls.insert(line, at: at)
    }
    return ls.joined(separator: "\n")
}

/// Adds `- fact` under `## Learned` unless an equivalent fact is already stored anywhere in the file. nil = nothing to add.
func appendingLearned(to text: String, fact: String) -> String? {
    let f = fact.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !f.isEmpty else { return nil }
    let known = learnedFacts(text) + profileFields(text).filter { !$0.value.isEmpty }.map { "\($0.key) \($0.value)" }
    if known.contains(where: { $0.lowercased() == f.lowercased() || similarFact($0, f) }) { return nil }
    var ls = lines(text)
    while let l = ls.last, l.trimmingCharacters(in: .whitespaces).isEmpty { ls.removeLast() }
    guard let h = ls.firstIndex(of: learnedHeading) else { return (ls + ["", learnedHeading, "- " + f]).joined(separator: "\n") }
    var at = h + 1
    while at < ls.count, !ls[at].hasPrefix("## ") { at += 1 }
    ls.insert("- " + f, at: at)
    return ls.joined(separator: "\n")
}

/// The profile as the model sees it: filled fields, learned facts (latest ones if long), and what is still missing.
func renderProfile(_ text: String, cap: Int = 3500) -> String {
    let fields = profileFields(text)
    let filled = fields.filter { !$0.value.isEmpty }.map { "\($0.key): \($0.value)" }
    let missing = fields.filter { $0.value.isEmpty }.map(\.key)
    var out = filled.joined(separator: "\n")
    var learned = learnedFacts(text)
    var more = false
    while (out.count + learned.reduce(0) { $0 + $1.count + 3 }) > cap, learned.count > 10 { learned.removeFirst(); more = true }
    if !learned.isEmpty { out += "\nLearned:\n" + learned.map { "- " + $0 }.joined(separator: "\n") }
    if more { out += "\n(older learned facts exist: call recall)" }
    // free-form sections the user wrote by hand
    let ls = lines(text)
    var extra = "", inExtra = false
    for l in ls[headIndex(ls)...] {
        if l.hasPrefix("## ") { inExtra = l != learnedHeading }
        if inExtra { extra += l + "\n" }
    }
    if !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out += "\n" + String(extra.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200)) }
    if !missing.isEmpty { out += "\nNot set yet: " + missing.joined(separator: ", ") }
    return out
}

/// Weak words match too many form questions ("Company name" is not the user's name), so they count less.
private let weakKey: Set<String> = ["name"]

/// For each form question, the profile value that most likely answers it (advisory: the model still checks it fits).
func profileHints(questions: [String], in text: String) -> [(question: String, answer: String)] {
    let fields = profileFields(text).filter { !$0.value.isEmpty && !$0.key.lowercased().contains("style") && !$0.key.lowercased().contains("preference") }
    let learned = learnedFacts(text)
    let learnedDocs = learned.map(tokens)
    var out: [(String, String)] = []
    for q in questions {
        let qt = Set(tokens(q))
        guard !qt.isEmpty else { continue }
        var best: (score: Int, value: String)?
        for f in fields {
            let hit = Set(tokens(f.key)).intersection(qt)
            // "name" alone only answers a question about the person ("Full name"), not "Company name" or "Pet name"
            if hit.isSubset(of: weakKey), !qt.subtracting(weakKey).subtracting(["full", "first", "last", "legal", "preferred"]).isEmpty { continue }
            let score = hit.reduce(0) { $0 + (weakKey.contains($1) ? 1 : 3) }
            if score > 0, score > (best?.score ?? 0) { best = (score, f.value) }
        }
        if let b = best { out.append((q, b.value)); continue }
        let bm = bm25(query: Array(qt), docs: learnedDocs)
        if let i = bm.indices.max(by: { bm[$0] < bm[$1] }), bm[i] >= 1.5 { out.append((q, learned[i])) }
    }
    return out
}
