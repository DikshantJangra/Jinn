import Foundation

func systemPrompt(_ ctx: String) -> String {
    """
    You are Jinn, a local assistant running on the user's Mac. Everything stays on this machine.
    Replies are spoken aloud: one or two short sentences, no markdown.

    HOW YOU WORK ON ANY APP OR WEBSITE (no app-specific training needed): look, then act, then check.
    1. look: lists what is on screen as #id role "label" (works for native apps, websites, anything with text).
    2. act (click | type | press | scroll | wait) with target = a #id from your latest look, or the visible text. It returns what changed.
    3. Read that result. If it says No visible change or an error, look again and try a different element or route (scroll, open a menu, press a key, another way to the same goal). Keep going until the goal is truly reached.
    Typing needs a focused text box: to reply or compose, click Reply/Compose first, look again, click the box, then type. If look shows only text, click the text you want and look again.
    Navigate yourself: to reply to an email, open the message row, then press Reply, then type, then Send. Nobody will tell you where buttons are; look for them. If the target is not on screen, scroll, switch tabs/folders, search, or open it first.

    NEVER INVENT. Use only ids, labels, names and facts that a tool result showed you. If you did not see it, look again or say you do not see it. Do not claim something is done, sent, filled, opened or saved unless a tool result confirmed it. Quote what you saw when you summarize. A personal fact that is in neither the user profile below nor on screen: ask for it once, listing everything you are missing.
    Never tell the user to do a step manually; do it, and only say you cannot after tools actually failed. The user is asked to approve risky steps (sending, submitting, paying, deleting) automatically, so go ahead and try them when the user asked for them; never do them when they did not.

    SHORTCUTS exist for common jobs; use one if it fits, otherwise use look/act: gmail_reply, reply_mail, send_chat / find_chat (WhatsApp, Telegram, Slack, Discord), chrome_open + chrome_fill_form + chrome_next (web and Google forms: it matches questions by wording and reports what is still unanswered), draft_mail, send_message, web_search / web_fetch / ping / open_url, files (find_files, open_file, read_file, write_file, move_file, copy_file, trash_file, reveal_in_finder, clipboard_get/set), apps (open_app, activate_app, quit_app, close_window, hide_app). When a page or app is slow, act wait for text to appear. For long text (an email) call look with full:true.
    "Open X" for a file means find_files then open_file. If Chrome says scripting is blocked, tell the user once to enable Chrome menu View > Developer > Allow JavaScript from Apple Events; meanwhile look/act still work through the accessibility tree and OCR.
    Today: \(Date().formatted(date: .complete, time: .omitted)).

    \(ctx)
    """
}

final class Agent {
    let small: Brain = makeBrain(env("JINN_MODEL") ?? "gemma4:e4b")
    let big: Brain? = env("JINN_BIG_MODEL").map(makeBrain)
    let tools = Dictionary(uniqueKeysWithValues: allTools.map { ($0.name, $0) })
    /// Fixed order: a byte-stable prompt prefix lets Ollama reuse its KV cache across rounds.
    /// The model sees few tools (a small model picks better): look/act drive the screen and dispatch to these internally.
    static let internalTools: Set<String> = ["screen_read", "app_state", "click", "set_value", "type_text", "press_key", "scroll", "perform_action", "screen_ocr", "click_text", "click_at", "move_cursor",
                                             "wait_for_text", "chrome_press", "chrome_type", "chrome_elements", "chrome_click", "chrome_tabs", "chrome_page", "chrome_read_form"]
    let schemas = allTools.filter { !Agent.internalTools.contains($0.name) }.map(\.schema)
    let maxRounds = Int(env("JINN_MAX_ROUNDS") ?? "") ?? 24
    var history: [Msg] = []
    var confirm: (@Sendable (ConfirmRequest) async -> Decision)?

    private func authorize(_ tool: Tool, _ args: [String: Any], _ summary: String) async -> String? {
        if let why = tool.vet?(args) { return "error: \(JinnError.blocked(why).message)" }
        let scope: String, persist: Bool
        switch tool.risk {
        case .safe: return nil
        case .confirm: scope = "tool:" + tool.name; persist = false
        case .app(let key):
            guard let app = try? Apps.target(args.opt(key)), let bid = app.bundleIdentifier?.lowercased()
            else { return "error: missing, unknown or blocked app" }
            scope = bid; persist = true
        }
        let always = tool.alwaysAsk || tool.askIf?(args) == true
        if !always && (PermissionMode.current == .auto || Approvals.shared.allowed(scope)) { return nil }
        let d = await confirm?(ConfirmRequest(tool: tool.name, summary: summary, scope: scope, persist: persist, session: !always)) ?? .deny
        if d == .deny { return "error: \(JinnError.declined.message)" }
        if d != .once && !always { Approvals.shared.grant(scope, always: d == .always) }
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
        var lastSig = "", repeats = 0, nudges = 0, checks = 0, acted = false
        var evidence = Evidence.none
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
                if checks < 2, let fix = finalCheck(text: r.text, evidence: evidence) {
                    checks += 1
                    emit("check: \(fix.prefix(80))")
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
                    if escalate(repeats >= 2 ? "same call 3 times" : "repeated failing call") {
                        result = "error: you already made this exact call; read its result and do something different"
                        repeats = 0
                    } else { return "Stopped: I kept repeating \(call.name) without progress." }
                } else if let tool = tools[call.name] {
                    var args = call.args
                    // no app named = "the one in front": pin it now so approval and action cannot differ if the user switches apps
                    if case .app(let key) = tool.risk, args.opt(key).isEmpty, let n = try? Apps.target("").localizedName { args[key] = n }
                    // show the user (and the trace) WHAT #id means when they are asked to approve it
                    if call.name == "act" { let l = resolvedLabel(args); args["label"] = l.isEmpty ? nil : l } // never keep a model-written label
                    if let gap = Permissions.accessibilityGap(tool) { result = gap }
                    else if let refusal = await authorize(tool, args, "\(call.name) \(argJSON)") { result = refusal }
                    else {
                        // a success may change state (open_app, then app_state again), so earlier failures may now work
                        do { result = try await tool.run(args); failed.removeAll() }
                        catch { result = "error: \(explain(error))"; failed.insert(sig) }
                    }
                } else {
                    result = "error: unknown tool \(call.name). Available: \(allTools.map(\.name).filter { !Agent.internalTools.contains($0) }.joined(separator: ", "))"; failed.insert(sig)
                }
                if result.hasPrefix("error:"), uiTools.contains(call.name) { result += "\nRecovery: call look again, then try a different element or route. Do not repeat this call and do not ask the user to do it manually." }
                evidence = nextEvidence(tool: call.name, result: result, was: evidence)
                result = String(result.prefix(4000))
                Trace.log(tool: call.name, args: argJSON, result: result, ms: Int(Date().timeIntervalSince(t0) * 1000))
                emit("<- \(result.prefix(300))")
                messages.append(["role": "tool", "content": result, "tool_name": call.name])
            }
            if round == limit, escalate("hit \(limit) rounds") { limit += maxRounds }
        }
        return "Stopped after \(limit) tool rounds."
    }
}

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

/// Tools that drive the screen: their success is only believable if the screen showed a change.
let uiTools: Set<String> = ["act", "click", "set_value", "type_text", "press_key", "scroll", "perform_action", "click_text", "click_at", "chrome_press", "chrome_type", "chrome_click", "chrome_next", "chrome_fill_form"]
/// Tools that put fresh screen state in front of the model.
let lookTools: Set<String> = ["look", "app_state", "screen_read", "screen_ocr", "chrome_page", "chrome_read_form", "chrome_elements", "chrome_open", "wait_for_text"]

/// What the model can honestly claim: nothing acted yet, last UI action confirmed on screen, it failed or changed nothing, or nobody checked.
enum Evidence { case none, verified, failed, unverified }

func nextEvidence(tool: String, result: String, was: Evidence) -> Evidence {
    if lookTools.contains(tool) { return result.hasPrefix("error:") ? was : .verified }
    guard uiTools.contains(tool) else { return was }
    if result.hasPrefix("error:") || result.contains("No visible change") { return .failed }
    return result.contains("Changed:") || tool == "chrome_fill_form" || tool == "chrome_next" ? .verified : .unverified
}

/// Stops an unfounded "done": a failed last step cannot be reported as success, and an unchecked one must be checked first.
func finalCheck(text: String, evidence: Evidence) -> String? {
    let l = text.lowercased()
    switch evidence {
    case .failed where ["sent", "replied", "done", "filled", "opened", "clicked", "submitted", "completed", "saved", "finished", "typed", "written", "ready"].contains(where: l.contains):
        return "Your last screen action failed or changed nothing, so do not report success. Call look, then try a different way, or tell the user exactly what failed."
    case .unverified:
        return "You acted but never checked the result. Call look now, confirm it on screen, then report only what you actually see."
    default: return nil
    }
}
