import Foundation

/// .safe runs freely; .confirm asks the HUD every call; .app(argKey) asks once per app named in that argument.
enum Risk { case safe, confirm, app(String) }

/// One callable tool. All params are strings; a "(optional)" description prefix marks it not required.
struct Tool {
    let name: String
    let description: String
    var params: [String: String] = [:]
    var risk: Risk = .safe
    /// Hard pre-check before any approval prompt: return a reason to refuse outright.
    var vet: (([String: Any]) -> String?)?
    /// Outbound or argument-sensitive (shell, messages): asked on every call, never covered by Auto mode or a session grant.
    var alwaysAsk = false
    let run: ([String: Any]) async throws -> String

    var schema: [String: Any] { [
        "type": "function",
        "function": [
            "name": name, "description": description,
            "parameters": [
                "type": "object",
                "properties": params.mapValues { ["type": "string", "description": $0] },
                "required": params.filter { !$0.value.hasPrefix("(optional)") }.map(\.key),
            ] as [String: Any],
        ] as [String: Any],
    ] }
}

extension Dictionary where Key == String, Value == Any {
    /// String arg; objects/arrays (models sometimes send them unstringified) are re-serialized to JSON.
    func str(_ k: String) throws -> String {
        guard let v = self[k], !(v is NSNull) else { throw JinnError("missing arg: \(k)") }
        if let s = v as? String { return s }
        if v is [String: Any] || v is [Any], let d = try? JSONSerialization.data(withJSONObject: v) { return String(decoding: d, as: UTF8.self) }
        return "\(v)"
    }
    func opt(_ k: String) -> String { (try? str(k)) ?? "" }
}

let allTools: [Tool] = fileTools + systemTools + appTools + webTools + axTools + screenTools + controlTools + chromeTools + shellTools + [rememberTool]
