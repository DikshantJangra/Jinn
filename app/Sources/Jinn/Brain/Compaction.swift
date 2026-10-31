import Foundation

private func size(_ m: [Msg]) -> Int { m.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) } }

/// Keeps history inside a small model's context: old tool output is clipped first, then whole oldest turns are dropped.
/// The system message and the latest turn always survive; a dropped turn takes its tool replies with it.
func compact(_ messages: [Msg], keepRecent: Int = 8, budget: Int = 24000) -> [Msg] {
    var m = messages
    let old = max(0, m.count - keepRecent)
    for i in 0..<old where m[i]["role"] as? String == "tool" {
        if let c = m[i]["content"] as? String, c.count > 200 { m[i]["content"] = String(c.prefix(200)) + " …[clipped]" }
    }
    while size(m) > budget {
        // next user turn boundary after the first turn
        guard let next = m.indices.dropFirst(2).first(where: { m[$0]["role"] as? String == "user" }) else { break }
        m.removeSubrange(1..<next)
    }
    return m
}
