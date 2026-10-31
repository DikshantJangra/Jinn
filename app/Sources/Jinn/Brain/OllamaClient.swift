import Foundation

func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }

struct OllamaClient: Brain {
    var model: String
    let base = URL(string: "http://localhost:11434")!
    /// Ollama's default context is small and it silently drops the start of the prompt (our system prompt) when
    /// exceeded. JINN_CTX overrides; 16k fits prompt + tool schemas + a pruned UI snapshot.
    var contextSize = Int(env("JINN_CTX") ?? "") ?? 16384

    func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = "POST"
        r.timeoutInterval = 300
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: r) }
        catch { throw JinnError("Ollama not reachable on :11434 (run `ollama serve`): \(error.localizedDescription)") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw JinnError("bad Ollama response") }
        if let e = obj["error"] as? String { throw JinnError("Ollama: \(e)") }
        return obj
    }

    func body(_ messages: [Msg], tools: [[String: Any]]) -> [String: Any] {
        var b: [String: Any] = [
            "model": model, "messages": messages, "stream": false,
            "keep_alive": "30m", // keep weights + KV cache loaded between turns (default 5m causes cold starts)
            "options": ["num_ctx": contextSize, "num_predict": 2048],
        ]
        if !tools.isEmpty { b["tools"] = tools }
        return b
    }

    func chat(_ messages: [Msg], tools: [[String: Any]]) async throws -> Reply {
        let res = try await post("api/chat", body(messages, tools: tools))
        let m = res["message"] as? [String: Any] ?? [:]
        var calls = (m["tool_calls"] as? [[String: Any]] ?? []).compactMap { c -> ToolCall? in
            guard let f = c["function"] as? [String: Any], let n = f["name"] as? String else { return nil }
            // arguments is normally an object; some models send a JSON string
            let args = f["arguments"] as? [String: Any]
                ?? (f["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
            return ToolCall(name: n, args: args)
        }
        var msg = m
        let text = m["content"] as? String ?? ""
        if calls.isEmpty, let t = TextToolCalls.first(in: text, names: allTools.map(\.name)) {
            calls = [t]
            msg["content"] = ""
            msg["tool_calls"] = [["function": ["name": t.name, "arguments": t.args]]]
        }
        return Reply(msg: msg, text: calls.isEmpty ? text : "", calls: calls, truncated: res["done_reason"] as? String == "length")
    }

    /// Loads the model into memory ahead of the first request (empty generate = load only).
    func warm() async { _ = try? await post("api/generate", ["model": model, "keep_alive": "30m"]) }

    func embed(_ text: String) async throws -> [Float] {
        let res = try await post("api/embeddings", ["model": "nomic-embed-text", "prompt": text, "keep_alive": "30m"])
        return (res["embedding"] as? [Double] ?? []).map(Float.init)
    }
}
