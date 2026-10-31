// firstJSON and first(in:names:) are adapted from Agent! (https://github.com/macos26/Agent)
// Agent/Services/OllamaService.swift (extractFirstJSON, extractFirstToolCall).
// Required Notice: Copyright (c) 2026 AgentiLoop.ai, a Logos InkPen LLC company (https://AgentiLoop.ai)
// Licensed under the PolyForm Noncommercial License 1.0.0 (https://polyformproject.org/licenses/noncommercial/1.0.0).
// This file is NOT covered by Jinn's MIT license: noncommercial use only. Delete it and its call in OllamaClient before commercial use.
import Foundation

/// Local models sometimes write a tool call as plain text (`list_dir {"path":"~"}`) instead of using native tool_calls.
enum TextToolCalls {
    /// First balanced `{...}` object at the start of `text`.
    static func firstJSON(_ text: String) -> [String: Any]? {
        var depth = 0, inString = false, escape = false
        var end: String.Index?
        for i in text.indices {
            let c = text[i]
            if escape { escape = false; continue }
            if c == "\\" && inString { escape = true; continue }
            if c == "\"" { inString.toggle(); continue }
            if inString { continue }
            if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { end = text.index(after: i); break } }
        }
        guard let end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[text.startIndex..<end].utf8))) as? [String: Any]
    }

    /// Earliest known tool name followed (within 20 chars of junk) by a JSON object.
    static func first(in text: String, names: [String]) -> ToolCall? {
        var best: (ToolCall, String.Index)?
        for name in names {
            guard let r = text.range(of: name) else { continue }
            if let b = best, r.lowerBound >= b.1 { continue }
            guard let brace = text[r.upperBound...].firstIndex(of: "{"), text.distance(from: r.upperBound, to: brace) <= 20,
                  let args = firstJSON(String(text[brace...])) else { continue }
            best = (ToolCall(name: name, args: args), r.lowerBound)
        }
        return best?.0
    }
}
