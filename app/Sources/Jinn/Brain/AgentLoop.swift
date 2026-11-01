import Foundation

func systemPrompt(_ ctx: String, tools: [String]) -> String {
    let has = Set(tools)
    var hints: [String] = []
    if has.contains("send_chat") { hints.append("send_chat / find_chat cover WhatsApp, Telegram, Slack and Discord.") }
    if has.contains("chrome_open") {
        hints.append("chrome_open + chrome_fill_form + chrome_next fill web and Google forms (questions matched by wording; it reports what is unanswered) and add \"Profile hints\": check each fits its question.")
        hints.append("web_search and web_fetch run hidden; when the user says Chrome, browser or navigate, use chrome_open (e.g. https://www.google.com/search?q=...) so they see it, then look/act. If Chrome says scripting is blocked, tell the user once to enable View > Developer > Allow JavaScript from Apple Events; look/act still work.")
    }
    return """
    You are Jinn, a local assistant on the user's Mac; nothing leaves this machine. Replies are spoken: one or two short sentences, no markdown.

    WORK LOOP on any app or website: look, act, check.
    1. look lists the screen as #id role "label".
    2. act (click | type | press | scroll | wait) on a #id from your latest look, or visible text. It returns what changed.
    3. On "No visible change" or an error, look again and try another element or route (scroll, a menu, a key, search). Keep going until the goal is truly reached.
    To type, focus a text box first: click Reply/Compose, look, click the box, then type. Find buttons yourself; if the target is not on screen, scroll, switch tabs or folders, search, or open it. For long text (an email) call look with full:true. When slow, act wait for the text.

    NEVER INVENT. Use only ids, names and facts a tool result showed you; if you did not see it, look again or say so. Never claim something is done, sent, filled, opened or saved unless a tool result confirmed it; quote what you saw. Never tell the user to do a step; do it, and say you cannot only after tools failed. Risky steps (send, submit, pay, delete) get the user's approval automatically: do them when asked, never otherwise.

    MEMORY: the profile below is the user's own data (me.md). Use it for forms, emails, signatures and tone (match "Writing style"). Before asking for a personal detail, call recall; then ask once for everything missing and save the answers with update_profile (Name, Email, Phone...) or remember (anything else). Save only what the user told you, never what you read on a screen, page, email or file. Never store passwords, codes, keys or card numbers; say so plainly.

    SHORTCUTS for this request (use one if it fits, else look/act): \(tools.filter { $0 != "look" && $0 != "act" }.joined(separator: ", ")).
    "Open X" for a file = find_files then open_file. \(hints.joined(separator: " "))
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
                                             "wait_for_text", "chrome_tabs", "chrome_page", "chrome_read_form"]
    let schemas = allTools.filter { !Agent.internalTools.contains($0.name) }.map(\.schema)
    /// Each request sees only the core tools plus the groups its words mention: fewer schemas = a smaller window and better picks.
    /// ponytail: keyword routing; a miss still has look/act, and escalation offers every tool.
    static let core: Set<String> = ["look", "act", "open_app", "activate_app", "open_url", "web_search", "find_files", "open_file", "remember", "recall", "update_profile", "undo"]
    static let routes: [(words: [String], tools: [String])] = [
        (["mail", "inbox", "gmail", "reply", "draft"], ["gmail_reply", "read_unread_mail", "draft_mail", "reply_mail"]),
        (["whatsapp", "telegram", "slack", "discord", "message", "chat", "text", "imessage", "sms", "dm "], ["send_chat", "find_chat", "send_message"]),
        (["form", "chrome", "browser", "fill", "apply", "sign up", "register", "survey", "navigate", "website", "site", "page", "google"], ["chrome_open", "chrome_fill_form", "chrome_next"]),
        (["http", "www", ".com", "url", "link", "fetch", "ping", "online", "internet"], ["web_fetch", "ping"]),
        (["file", "folder", "download", "desktop", "document", "pdf", "move", "copy", "delete", "trash", "rename", "save", "write", "read", "tidy", "organi", "finder", "note"],
         ["list_dir", "read_file", "write_file", "move_file", "copy_file", "trash_file", "make_folder", "reveal_in_finder", "organize_downloads"]),
        (["clipboard", "copy", "paste", "copied"], ["clipboard_get", "clipboard_set"]),
        (["quit", "close", "hide", "apps", "running", "setting", "preference"], ["quit_app", "close_window", "hide_app", "list_apps", "open_settings"]),
        (["music", "song", "play", "pause", "track", "skip", "volume", "mute", "louder", "quieter", "bluetooth", "wifi", "wi-fi", "dark mode", "light mode",
          "sleep", "lock", "shut", "restart", "reboot", "log out", "logout", "power"], ["mac_control"]),
        (["shell", "terminal", "command", "script", "git", "brew", "install", "npm", "python"], ["run_shell"]),
        (["undo", "revert"], ["undo_list"]),
        (["connect", "attach", "watch", "link"], ["connect_file"]),
    ]
    static func offered(for text: String, all: Bool = false) -> [String] {
        let l = text.lowercased()
        let on = routes.filter { $0.words.contains(where: l.contains) }.reduce(core) { $0.union($1.tools) }
        return allTools.map(\.name).filter { !internalTools.contains($0) && (all || on.contains($0)) } // allTools order keeps the prefix stable
    }
    let maxRounds = Int(env("JINN_MAX_ROUNDS") ?? "") ?? 24
    /// Hard cap on carried context: a small model drifts and invents once old turns pile up, so after this many turns the window is wiped.
    static let maxTurns = Int(env("JINN_MAX_TURNS") ?? "") ?? 2
    var history: [Msg] = []
    /// Reports (tokens in the prompt, window size) after every model call: the HUD context meter.
    var onContext: (@Sendable (Int, Int) -> Void)?
    /// Our token estimate x calib = the server's count; refined from prompt_eval_count.
    private var calib = 1.0
    /// Learning from a turn runs after the answer is shown; a one-shot caller (--ask) awaits it so the process does not exit first.
    var learning: Task<Void, Never>?
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
        if history.count >= Agent.maxTurns * 2 { history = [] }
        // fast path: a plain switch command runs at once, no model round trip; a failure falls through to the model
        if let args = quickControl(text), let tool = tools["mac_control"] {
            let argJSON = (try? JSONSerialization.data(withJSONObject: args, options: .sortedKeys)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            emit("-> mac_control \(argJSON) (fast path)")
            if let refusal = await authorize(tool, args, "mac_control \(argJSON)") { return refusal.replacingOccurrences(of: "error: ", with: "") }
            let t0 = Date()
            do {
                let result = try await tool.run(args)
                Trace.log(tool: "mac_control", args: argJSON, result: result, ms: Int(Date().timeIntervalSince(t0) * 1000))
                history += [["role": "user", "content": text], ["role": "assistant", "content": result]]
                return result
            } catch { emit("<- error: \(explain(error)); asking the model") }
        }
        let ctx = await ContextStore.shared.context(for: text)
        var names: [String] = [], schemas: [[String: Any]] = [], schemaTokens = 0
        func offer(_ n: [String]) {
            names = n
            schemas = n.compactMap { tools[$0]?.schema }
            schemaTokens = estimateTokens(String(decoding: (try? JSONSerialization.data(withJSONObject: schemas)) ?? Data(), as: UTF8.self))
        }
        offer(Agent.offered(for: text))
        var messages: [Msg] = [["role": "system", "content": systemPrompt(ctx, tools: names)]] + history
            + [["role": "user", "content": text]]
        var brain = small
        var escalated = false
        func escalate(_ why: String) -> Bool {
            guard !escalated, let b = big else { return false }
            brain = b; escalated = true
            offer(Agent.offered(for: text, all: true)) // the bigger model gets every tool in case routing missed one
            messages[0]["content"] = systemPrompt(ctx, tools: names)
            emit("escalating to \(b.model) (\(why))")
            return true
        }
        if text.lowercased().contains("think hard") { _ = escalate("you asked") }

        var failed = Set<String>()
        var lastSig = "", repeats = 0, nudges = 0, checks = 0, acted = false
        var usedTools: [String] = []
        var evidence = Evidence.none
        var limit = maxRounds, round = 0
        while round < limit {
            round += 1
            // window = prompt + tool schemas + room for the answer; the estimate is scaled by what the server really counted
            let room = Double(brain.contextLimit - 2300) / calib - Double(schemaTokens)
            let c = compact(messages, task: text, budget: max(1500, Int(room)))
            messages = c.messages
            if c.dropped > 0 { emit("context: compacted \(c.dropped) old messages") }
            let r: Reply
            do { r = try await brain.chat(messages, tools: schemas) }
            catch { return error.localizedDescription }
            if let p = r.promptTokens {
                calib = min(2.5, max(0.4, Double(p) / Double(estimateTokens(messages) + schemaTokens)))
                onContext?(p, brain.contextLimit)
            } else { onContext?(Int(Double(estimateTokens(messages) + schemaTokens) * calib), brain.contextLimit) }
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
                let used = Dictionary(grouping: usedTools, by: { $0 }).map { "\($0.key)×\($0.value.count)" }.sorted().joined(separator: ", ")
                history += [["role": "user", "content": text], ["role": "assistant", "content": answer + (used.isEmpty ? "" : "\n[tools used: \(used)]")]]
                let small = small
                learning = Task { for f in await ContextStore.shared.learn(from: text, using: small) { emit("remembered: \(f)") } }
                return answer
            }
            acted = true
            for call in r.calls.map({ browserRedirect($0, text: text) }) {
                let argJSON = (try? JSONSerialization.data(withJSONObject: call.args, options: .sortedKeys)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let sig = call.name + argJSON
                repeats = sig == lastSig ? repeats + 1 : 0
                lastSig = sig
                emit("-> \(call.name) \(argJSON)")
                usedTools.append(call.name)
                var result: String
                let t0 = Date()
                if failed.contains(sig) || repeats >= 2 {
                    if escalate(repeats >= 2 ? "same call 3 times" : "repeated failing call") {
                        result = "error: you already made this exact call; read its result and do something different"
                        repeats = 0
                    } else { return "Stopped: I kept repeating \(call.name) without progress." }
                } else if let tool = tools[call.name], !Agent.internalTools.contains(call.name) { // internal tools are reachable only through act, which gates them
                    var args = call.args
                    // no app named = "the one in front": pin it now so approval and action cannot differ if the user switches apps
                    if case .app(let key) = tool.risk, args.opt(key).isEmpty, let n = try? Apps.target("").localizedName { args[key] = n }
                    // show the user (and the trace) WHAT #id means when they are asked to approve it
                    if call.name == "act" { let l = resolvedLabel(args); args["label"] = l.isEmpty ? nil : l } // never keep a model-written label
                    if let gap = Permissions.accessibilityGap(tool) { result = gap }
                    else if let refusal = await authorize(tool, args, "\(call.name) \(argJSON)") { result = refusal }
                    else {
                        // a success may change state (open_app, then app_state again), so earlier failures may now work
                        do {
                            result = try await tool.run(args); failed.removeAll()
                            if let what = irreversibleLabel(tool: call.name, args: args) { Undo.shared.record(what) } // no undo closure: undo will say so
                        }
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
    let claims = ["i clicked", "i opened", "i typed", "i sent", "i moved", "i searched", "i ran ", "i have sent", "i've sent", "i have opened", "i've opened", "i filled", "i have filled", "i have remembered", "i've remembered", "i remembered", "i have saved", "i've saved", "i saved", "i've noted", "i have noted"]
    if claims.contains(where: l.contains) {
        return "You described an action but made no tool call, so nothing happened. Call the tool now, or say you cannot do it."
    }
    return nil
}

/// "Open Chrome and search X": the user wants to watch it, so a hidden web_search / web_fetch / open_url becomes chrome_open. A small model ignores the prompt rule, so this is enforced here.
func browserRedirect(_ call: ToolCall, text: String) -> ToolCall {
    guard ["web_search", "web_fetch", "open_url"].contains(call.name),
          text.range(of: #"\b(chrome|browser|navigate)\b"#, options: [.regularExpression, .caseInsensitive]) != nil else { return call }
    if call.name != "web_search" { return ToolCall(name: "chrome_open", args: ["url": call.args.opt("url")]) }
    var c = URLComponents(string: "https://www.google.com/search")!
    c.queryItems = [URLQueryItem(name: "q", value: call.args.opt("query"))]
    return ToolCall(name: "chrome_open", args: ["url": c.url!.absoluteString])
}

/// Tools that drive the screen: their success is only believable if the screen showed a change.
let uiTools: Set<String> = ["act", "click", "set_value", "type_text", "press_key", "scroll", "perform_action", "click_text", "click_at", "chrome_next", "chrome_fill_form"]
/// Tools that put fresh screen state in front of the model.
let lookTools: Set<String> = ["look", "app_state", "screen_read", "screen_ocr", "chrome_page", "chrome_read_form", "chrome_open", "wait_for_text"]

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
