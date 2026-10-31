import Foundation

func env(_ k: String) -> String? { ProcessInfo.processInfo.environment[k] }

struct OllamaClient: Brain {
    var model: String
    let base = URL(string: "http://localhost:11434")!
    var contextSize = Int(env("JINN_CTX") ?? "") ?? 16384
    var contextLimit: Int { contextSize }

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
            "keep_alive": "30m",
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
        return Reply(msg: msg, text: calls.isEmpty ? text : "", calls: calls, truncated: res["done_reason"] as? String == "length", promptTokens: res["prompt_eval_count"] as? Int)
    }

    func warm() async { _ = try? await post("api/generate", ["model": model, "keep_alive": "30m"]) }

    static let embedModel = "nomic-embed-text"

    /// One batched call. nomic-embed-text was trained with task prefixes and Ollama does not add them,
    /// so queries and stored text must be marked differently or retrieval quality drops.
    func embed(_ texts: [String], query: Bool) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let prefix = query ? "search_query: " : "search_document: "
        let res = try await post("api/embed", ["model": Self.embedModel, "input": texts.map { prefix + $0 }, "keep_alive": "30m"])
        let out = (res["embeddings"] as? [[Double]] ?? []).map { $0.map(Float.init) }
        guard out.count == texts.count else { throw JinnError("embedding model returned \(out.count) vectors for \(texts.count) texts (ollama pull \(Self.embedModel))") }
        return out
    }
}
