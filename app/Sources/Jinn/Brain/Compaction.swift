import Foundation

private func size(_ m: [Msg]) -> Int { m.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) } }

func compact(_ messages: [Msg], keepRecent: Int = 8, budget: Int = 24000) -> [Msg] {
    var m = messages
    let old = max(0, m.count - keepRecent)
    for i in 0..<old where m[i]["role"] as? String == "tool" {
        if let c = m[i]["content"] as? String, c.count > 200 { m[i]["content"] = String(c.prefix(200)) + " …[clipped]" }
    }
    while size(m) > budget {
        guard let next = m.indices.dropFirst(2).first(where: { m[$0]["role"] as? String == "user" }) else { break }
        m.removeSubrange(1..<next)
    }
    return m
}
