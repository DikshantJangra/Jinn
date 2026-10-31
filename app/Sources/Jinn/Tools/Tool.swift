import Foundation

enum Risk { case safe, confirm, app(String) }

struct Tool {
    let name: String
    let description: String
    var params: [String: String] = [:]
    var risk: Risk = .safe
    var vet: (([String: Any]) -> String?)?
    var alwaysAsk = false
    /// Per-call version of alwaysAsk: asked every time when this returns true for the call's arguments (e.g. the target looks like Send/Delete).
    var askIf: (([String: Any]) -> Bool)?
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
    func str(_ k: String) throws -> String {
        guard let v = self[k], !(v is NSNull) else { throw JinnError("missing arg: \(k)") }
        if let s = v as? String { return s }
        if v is [String: Any] || v is [Any], let d = try? JSONSerialization.data(withJSONObject: v) { return String(decoding: d, as: UTF8.self) }
        return "\(v)"
    }
    func opt(_ k: String) -> String { (try? str(k)) ?? "" }
}

let allTools: [Tool] = fileTools + systemTools + appTools + webTools + universalTools + axTools + screenTools + controlTools + chromeTools + shellTools + [rememberTool]
