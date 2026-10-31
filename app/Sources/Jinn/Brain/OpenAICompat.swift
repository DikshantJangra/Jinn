import Foundation

struct OpenAICompatClient: Brain {
    var model: String
    let base: URL

    func wire(_ messages: [Msg]) -> [Msg] {
        var out: [Msg] = [], pending: [String] = [], n = 0
        for m in messages {
            var m = m
            if m["role"] as? String == "assistant", let calls = m["tool_calls"] as? [[String: Any]] {
                m["tool_calls"] = calls.map { c -> Msg in
                    let f = c["function"] as? [String: Any] ?? [:]
                    n += 1; pending.append("call_\(n)")
                    let args = (try? JSONSerialization.data(withJSONObject: f["arguments"] ?? [:])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                    return ["id": "call_\(n)", "type": "function", "function": ["name": f["name"] ?? "", "arguments": args]]
                }
            } else if m["role"] as? String == "tool" {
                m["tool_call_id"] = pending.isEmpty ? "call_0" : pending.removeFirst()
                m["tool_name"] = nil
            }
            out.append(m)
        }
        return out
    }

    func chat(_ messages: [Msg], tools: [[String: Any]]) async throws -> Reply {
        var body: [String: Any] = ["model": model, "messages": wire(messages)]
        if !tools.isEmpty { body["tools"] = tools }
        var r = URLRequest(url: base.appendingPathComponent("v1/chat/completions"))
        r.httpMethod = "POST"; r.timeoutInterval = 300
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: r) }
        catch { throw JinnError("model server not reachable at \(base.absoluteString): \(error.localizedDescription)") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let e = (obj["error"] as? [String: Any])?["message"] as? String { throw JinnError("model server: \(e)") }
        let choice = (obj["choices"] as? [[String: Any]])?.first ?? [:]
        let m = (choice["message"] as? [String: Any]) ?? [:]
        var calls: [ToolCall] = [], echoed: [Msg] = []
        for c in m["tool_calls"] as? [[String: Any]] ?? [] {
            guard let f = c["function"] as? [String: Any], let name = f["name"] as? String else { continue }
            let args = (f["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            calls.append(ToolCall(name: name, args: args))
            echoed.append(["function": ["name": name, "arguments": args]])
        }
        let text = m["content"] as? String ?? ""
        var msg: Msg = ["role": "assistant", "content": text]
        if !echoed.isEmpty { msg["tool_calls"] = echoed }
        return Reply(msg: msg, text: text, calls: calls, truncated: choice["finish_reason"] as? String == "length")
    }
}
