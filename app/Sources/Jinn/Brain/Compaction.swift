import Foundation

/// Rough token count. ponytail: 3 bytes/token is conservative for English + JSON; the agent loop calibrates it
/// against the model's own prompt_eval_count so drift corrects itself.
func tokens(_ s: String) -> Int { (s.utf8.count + 2) / 3 }
func tokens(_ m: [Msg]) -> Int {
    m.reduce(0) { n, x in
        var t = tokens(x["content"] as? String ?? "") + 4
        if let c = x["tool_calls"], let d = try? JSONSerialization.data(withJSONObject: c) { t += (d.count + 2) / 3 }
        return n + t
    }
}

private func role(_ m: Msg) -> String { m["role"] as? String ?? "" }
private func text(_ m: Msg) -> String { m["content"] as? String ?? "" }
private let digestTag = "[Progress so far, older steps compacted: "

/// One line per dropped step so the model still knows what it already did: `act{click,#3} -> clicked… | look -> …`.
private func digest(_ group: ArraySlice<Msg>) -> String {
    var parts: [String] = []
    for m in group where role(m) == "assistant" {
        for c in m["tool_calls"] as? [[String: Any]] ?? [] {
            let f = c["function"] as? [String: Any] ?? [:]
            let args = (f["arguments"] as? [String: Any] ?? [:]).values.map { "\($0)" }.joined(separator: ",").prefix(50)
            parts.append("\(f["name"] ?? "?")(\(args))")
        }
    }
    let results = group.filter { role($0) == "tool" }.map { text($0).replacingOccurrences(of: "\n", with: " ").prefix(70) }
    return parts.joined(separator: " ") + (results.isEmpty ? "" : " -> " + results.joined(separator: " | "))
}

struct Compacted { let messages: [Msg]; let dropped: Int }

/// Fits the conversation under `budget` (estimated tokens), cheapest loss first:
/// 1. superseded screen observations shrink to one line (a newer look makes them wrong anyway),
/// 2. old tool results are clipped,
/// 3. the oldest earlier turns go,
/// 4. the oldest steps of the current run become a digest line.
/// The system prompt, the task message and the newest step are never dropped.
func compact(_ messages: [Msg], task: String, budget: Int, keepRecent: Int = 8) -> Compacted {
    var m = messages, dropped = 0
    let isLook: (Msg) -> Bool = { role($0) == "tool" && lookTools.contains($0["tool_name"] as? String ?? "") }
    let lastLook = m.lastIndex(where: isLook)
    for i in m.indices where isLook(m[i]) && i != lastLook && text(m[i]).count > 120 {
        m[i]["content"] = "[earlier \(m[i]["tool_name"] as? String ?? "look") output dropped: a newer look supersedes it]"
    }
    for i in 0..<max(0, m.count - keepRecent) where role(m[i]) == "tool" && text(m[i]).count > 300 {
        m[i]["content"] = String(text(m[i]).prefix(300)) + " …[clipped]"
    }
    func taskIndex() -> Int { m.lastIndex { role($0) == "user" && text($0) == task } ?? 1 }

    // 3. earlier turns: from index 1 up to the next user message, never past the task
    while tokens(m) > budget, taskIndex() > 1 {
        let ti = taskIndex()
        let end = m.indices.dropFirst(2).first { $0 <= ti && role(m[$0]) == "user" } ?? ti
        guard end > 1 else { break }
        dropped += end - 1
        m.removeSubrange(1..<end)
    }
    // 4. steps of this run: oldest assistant+tool group -> digest
    var lines: [String] = []
    if let d = m.firstIndex(where: { text($0).hasPrefix(digestTag) }) { lines = [String(text(m[d]).dropFirst(digestTag.count).dropLast())]; m.remove(at: d) }
    while tokens(m) + (lines.isEmpty ? 0 : 200) > budget {
        let ti = taskIndex()
        guard let a = m.indices.first(where: { $0 > ti && role(m[$0]) == "assistant" }) else { break }
        let end = m.indices.first { $0 > a && role(m[$0]) == "assistant" } ?? m.count
        guard end < m.count else { break }      // the newest step stays
        lines.append(digest(m[a..<end]))
        dropped += end - a
        m.removeSubrange(a..<end)
    }
    if !lines.isEmpty {
        let ti = taskIndex()
        m.insert(["role": "user", "content": digestTag + lines.suffix(12).joined(separator: " ; ").prefix(1500) + "]"], at: min(ti + 1, m.count))
    }
    return Compacted(messages: m, dropped: dropped)
}
