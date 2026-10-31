import Foundation

typealias Msg = [String: Any]
struct ToolCall { let name: String; let args: [String: Any] }

struct Reply {
    let msg: Msg
    let text: String
    let calls: [ToolCall]
    var truncated = false
}

protocol Brain {
    var model: String { get }
    func chat(_ messages: [Msg], tools: [[String: Any]]) async throws -> Reply
}

func makeBrain(_ model: String) -> Brain {
    env("JINN_BACKEND") == "openai" ? OpenAICompatClient(model: model, base: URL(string: env("JINN_BASE_URL") ?? "http://localhost:1234")!) : OllamaClient(model: model)
}
