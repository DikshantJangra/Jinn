import Foundation

typealias Msg = [String: Any]
struct ToolCall { let name: String; let args: [String: Any] }

struct Reply {
    let msg: Msg          // raw assistant message, appended back to history as-is
    let text: String
    let calls: [ToolCall]
    var truncated = false // output hit the token limit mid-answer
}

/// A model backend. Messages use Ollama's shape internally (assistant `tool_calls[].function.{name,arguments}`,
/// `tool` role replies); other backends convert at their boundary.
protocol Brain {
    var model: String { get }
    func chat(_ messages: [Msg], tools: [[String: Any]]) async throws -> Reply
}

/// JINN_BACKEND=ollama (default) | openai (any local OpenAI-compatible server: LM Studio, llama.cpp, vLLM; JINN_BASE_URL).
func makeBrain(_ model: String) -> Brain {
    env("JINN_BACKEND") == "openai" ? OpenAICompatClient(model: model, base: URL(string: env("JINN_BASE_URL") ?? "http://localhost:1234")!) : OllamaClient(model: model)
}
