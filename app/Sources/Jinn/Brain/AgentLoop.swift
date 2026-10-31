import Foundation

func systemPrompt(_ ctx: String) -> String {
    """
    You are Jinn, a local assistant running on the user's Mac. Everything stays on this machine.
    Act with tools instead of describing what you would do. Never invent tool results.
    Replies are spoken aloud: keep them to one or two short sentences, no markdown.
    To drive a Mac app: app_state first (it lists elements with [index]), then click / set_value / type_text / press_key using those indices.
    Indices are only valid for the latest app_state of that app; every action returns what changed, so read it before the next step.
    Prefer in this order: perform_action, set_value, click by index, press_key. Never guess an index.
    To fill a web form in Chrome: chrome_read_form, map labels to the user profile below, then chrome_fill_form. Never submit unless asked.
    If a tool fails, say what failed; do not retry the same call.
    Today: \(Date().formatted(date: .complete, time: .omitted)).

    \(ctx)
    """
}

final class Agent {
    let small: Brain = makeBrain(env("JINN_MODEL") ?? "gemma4:e4b")
    /// Optional escalation model (bigger local model). Set JINN_BIG_MODEL; nothing leaves the Mac unless you point it at a remote server.
    let big: Brain? = env("JINN_BIG_MODEL").map(makeBrain)
    let tools = Dictionary(uniqueKeysWithValues: allTools.map { ($0.name, $0) })
    /// Fixed order: a byte-stable prompt prefix lets Ollama reuse its KV cache across rounds.
    let schemas = allTools.map(\.schema)
    let maxRounds = Int(env("JINN_MAX_ROUNDS") ?? "") ?? 12
    var history: [Msg] = []
    /// Asked before any non-.safe tool runs. nil = deny (fail closed).
    var confirm: (@Sendable (ConfirmRequest) async -> Decision)?

    /// nil = go ahead, else the refusal text to hand back to the model.
    private func authorize(_ tool: Tool, _ args: [String: Any], _ summary: String) async -> String? {
        if let why = tool.vet?(args) { return "error: \(JinnError.blocked(why).message)" }
        var scope: String?
        switch tool.risk {
        case .safe: return nil
        case .confirm: break
        case .app(let key): // approvals are keyed on the resolved bundle id, never on the model-typed name
            guard let app = try? Apps.resolve(args.opt(key)), let bid = app.bundleIdentifier?.lowercased()
            else { return "error: missing, unknown or blocked app" }
            if Approvals.shared.allowed(bid) { return nil }
            scope = bid
        }
        let d = await confirm?(ConfirmRequest(tool: tool.name, summary: summary, scope: scope)) ?? .deny
        if d == .deny { return "error: \(JinnError.declined.message)" }
        if let scope { Approvals.shared.grant(scope, always: d == .always) }
        return nil
    }

    func run(_ text: String, emit: @escaping @Sendable (String) -> Void) async -> String {
        let ctx = await ContextStore.shared.context(for: text)
        var messages: [Msg] = [["role": "system", "content": systemPrompt(ctx)]] + history.suffix(20)
            + [["role": "user", "content": text]]
        var brain = small
        var escalated = false
        func escalate(_ why: String) -> Bool {
            guard !escalated, let b = big else { return false }
            brain = b; escalated = true
            emit("escalating to \(b.model) (\(why))")
            return true
        }
        if text.lowercased().contains("think hard") { _ = escalate("you asked") }

        var failed = Set<String>()
        var lastSig = "", repeats = 0, nudges = 0, acted = false
        var limit = maxRounds, round = 0
        while round < limit {
            round += 1
            messages = compact(messages)
            let r: Reply
            do { r = try await brain.chat(messages, tools: schemas) }
            catch { return error.localizedDescription }
            messages.append(r.msg)
            if r.calls.isEmpty {
                if nudges < 2, let fix = loopCorrection(text: r.text, truncated: r.truncated, acted: acted) {
                    nudges += 1
                    emit("nudge: \(fix.prefix(80))")
                    messages.append(["role": "user", "content": fix])
                    continue
                }
                let answer = r.text.isEmpty ? "Done." : r.text // Ollama rejects empty assistant turns
                history += [["role": "user", "content": text], ["role": "assistant", "content": answer]]
                return answer
            }
            acted = true
            for call in r.calls {
                let argJSON = (try? JSONSerialization.data(withJSONObject: call.args, options: .sortedKeys)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let sig = call.name + argJSON
                repeats = sig == lastSig ? repeats + 1 : 0
                lastSig = sig
                emit("-> \(call.name) \(argJSON)")
                var result: String
                let t0 = Date()
                if failed.contains(sig) || repeats >= 2 {
                    // stalled: repeating a failed call, or the same call 3x in a row
                    if escalate(repeats >= 2 ? "same call 3 times" : "repeated failing call") {
                        result = "error: you already made this exact call; read its result and do something different"
                        repeats = 0
                    } else { return "Stopped: I kept repeating \(call.name) without progress." }
                } else if let tool = tools[call.name] {
                    if let refusal = await authorize(tool, call.args, "\(call.name) \(argJSON)") { result = refusal }
                    else {
                        // a success may change state (open_app, then app_state again), so earlier failures may now work
                        do { result = try await tool.run(call.args); failed.removeAll() }
                        catch { result = "error: \(explain(error))"; failed.insert(sig) }
                    }
                } else {
                    result = "error: unknown tool \(call.name). Available: \(allTools.map(\.name).joined(separator: ", "))"; failed.insert(sig)
                }
                result = String(result.prefix(4000))
                Trace.log(tool: call.name, args: argJSON, result: result, ms: Int(Date().timeIntervalSince(t0) * 1000))
                emit("<- \(result.prefix(300))")
                messages.append(["role": "tool", "content": result, "tool_name": call.name])
            }
            // out of rounds: hand the same conversation to the bigger model instead of restarting (a restart would redo actions)
            if round == limit, escalate("hit \(limit) rounds") { limit += maxRounds }
        }
        return "Stopped after \(limit) tool rounds."
    }
}

/// Corrective message for a turn that ended without a tool call but should not end (ideas from Agent! LoopControl):
/// output cut off at the token limit, or a small model narrating an action it never performed.
/// A claim after tools already ran is a normal summary, so only a run with no tool calls at all is challenged.
func loopCorrection(text: String, truncated: Bool, acted: Bool) -> String? {
    if truncated { return "Your reply was cut off. Continue exactly where you stopped." }
    if acted { return nil }
    let l = text.lowercased()
    let claims = ["i clicked", "i opened", "i typed", "i sent", "i moved", "i searched", "i ran ", "i have sent", "i've sent", "i have opened", "i've opened", "i filled", "i have filled"]
    if claims.contains(where: l.contains) {
        return "You described an action but made no tool call, so nothing happened. Call the tool now, or say you cannot do it."
    }
    return nil
}
