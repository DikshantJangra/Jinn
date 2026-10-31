import Foundation

extension Chrome {
    /// Wording that sends, submits, pays or destroys: act asks the user before touching any of these.
    static let risky = try! NSRegularExpression(pattern: "\\b(send|submit|pay|buy|purchase|delete|remove|confirm|place order|post|publish)\\b", options: .caseInsensitive)
}

let chromeTools: [Tool] = [
    Tool(name: "chrome_tabs", description: "List the open Chrome tabs (title | url). Use a part of the url or title as url_contains in the other chrome tools.", risk: .confirm) { _ in
        try await Chrome.tabs()
    },
    Tool(name: "chrome_page", description: "Read a Chrome tab: title, URL and visible text. Works on tabs in the background.",
         params: ["url_contains": "(optional) part of the tab URL or title; default is the active tab"], risk: .confirm) { a in
        try await Chrome.eval(Chrome.page, tab: a.opt("url_contains"))
    },
    Tool(name: "chrome_open", description: "Open a URL in the user's Chrome (signed-in profile), wait for it to load, and return its questions/fields with ids, kinds, options and which are required. Use first for any Google Form or web form. No need to ask the user for field names; read them from the result.",
         params: ["url": "Full http(s) URL"], risk: .confirm, vet: { Web.vet($0.opt("url")) }) { a in
        let u = try Web.url(a)
        _ = try Shell.run("/usr/bin/open", ["-a", Chrome.appName, u.absoluteString])
        let hint = u.path.count > 8 ? u.path : ""
        var last = "page did not load"
        for _ in 0..<28 {
            try await Task.sleep(nanoseconds: 700_000_000)
            for h in (hint.isEmpty ? [""] : [hint, ""]) {
                guard let r = try? await Chrome.eval(Chrome.run("document.readyState==='complete'?JSON.stringify(status()):'loading'"), tab: h), r != "loading" else { continue }
                if r.contains("\"questions\":[{") { return r }
                last = r
            }
        }
        let page = (try? await Chrome.eval(Chrome.page)) ?? ""
        return "No form fields found yet. Page: \(page.prefix(1500)). If this is a sign-in page, ask the user to sign in, then call chrome_read_form. \(last.prefix(200))"
    },
    Tool(name: "chrome_read_form", description: "List the questions on the current Chrome page (Google Form or any web form): id, question, kind (text, paragraph, radio, checkbox, dropdown, select, date, time), options, required, answered, plus unanswered_required and the Next/Back/Submit buttons.",
         params: ["url_contains": "(optional) part of the tab URL or title to pick the tab"], risk: .confirm) { a in
        try await retry(2, base: 0.5) { try await Chrome.eval(Chrome.run("JSON.stringify(status())"), tab: a.opt("url_contains")) }
    },
    Tool(name: "chrome_fill_form", description: "Fill several questions at once on a Chrome page, without taking focus. Keys are question text (approximate is fine, matched fuzzily) or #id from chrome_read_form. Text: the answer. Radio/dropdown: the option text. Checkboxes: options comma separated. Dates: YYYY-MM-DD. Returns per-question results plus what is still unanswered; fix any 'not found' by using the listed questions/options, do not ask the user. Does not submit.",
         params: ["fields": "JSON object, e.g. {\"Email\":\"a@b.com\",\"#3\":\"Male\"}",
                  "url_contains": "(optional) part of the tab URL or title to pick the tab"], risk: .confirm) { a in
        let busy = try await Interrupt.waitIdle(pid: Chrome.pid)
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(try a.str("fields").utf8))) as? [String: Any]
        else { throw JinnError("fields must be a JSON object mapping question to answer, e.g. {\"Email\":\"a@b.com\"}") }
        let map = obj.mapValues { "\($0)" }, tab = a.opt("url_contains")
        let arg = Chrome.jsString(String(decoding: try JSONSerialization.data(withJSONObject: map), as: UTF8.self))
        let raw = try await retry(2, base: 0.5) { try await Chrome.eval(Chrome.run("JSON.stringify(fill(JSON.parse(\(arg))))"), tab: tab) }
        var res = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: String] ?? ["?": raw]
        // dropdowns only list their options once opened: open, wait, pick (retry once, they animate)
        for (k, v) in res where v.hasSuffix("PENDING") {
            guard let id = Int(v.dropFirst().prefix { $0.isNumber }) else { continue }
            var r = ""
            for _ in 0..<2 {
                _ = try await Chrome.eval(Chrome.run("openDD(\(id))"), tab: tab)
                try await Task.sleep(nanoseconds: 500_000_000)
                r = try await Chrome.eval(Chrome.run("pickDD(\(id),\(Chrome.jsString(map[k] ?? "")))"), tab: tab)
                if r.hasPrefix("ok") { break }
            }
            res[k] = "#\(id) \(r)"
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let status = (try? await Chrome.eval(Chrome.run("JSON.stringify(status())"), tab: tab)) ?? ""
        let out = String(decoding: (try? JSONSerialization.data(withJSONObject: res)) ?? Data(), as: UTF8.self)
        return "results: \(out)\nstatus: \(status)" + Interrupt.note(busy)
    },
    Tool(name: "chrome_next", description: "Go to the next page of a multi-page form (clicks Next/Continue; never Submit). Returns the new page's questions.",
         params: ["url_contains": "(optional) part of the tab URL or title to pick the tab"], risk: .confirm) { a in
        let tab = a.opt("url_contains")
        let r = try await Chrome.eval(Chrome.run("next()"), tab: tab)
        guard r.hasPrefix("clicked") else { return "\(r). If the form is complete, report that to the user; submit only if they asked." }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return r + "\n" + ((try? await Chrome.eval(Chrome.run("JSON.stringify(status())"), tab: tab)) ?? "")
    },
    Tool(name: "gmail_reply", description: "Reply to an email in Gmail (Chrome) end to end: finds the message in the inbox/search results by sender or subject text, opens it, clicks Reply, types your reply and, if send is true, sends it. The user is asked to approve first. Use this for any 'reply to the mail from X' request; do not look for the Reply button yourself.",
         params: ["find": "(optional) sender or subject text to find; omit if the email is already open", "text": "Reply text", "send": "(optional) true to send, otherwise leaves the reply open as a draft", "all": "(optional) true for Reply all"],
         risk: .confirm, alwaysAsk: true) { a in
        let tab = "mail.google.com", find = a.opt("find"), text = try a.str("text")
        func js(_ b: String) async throws -> String { try await Chrome.eval(Chrome.run(b), tab: tab) }
        func wait(_ what: String, _ cond: String, _ secs: Double = 8) async throws {
            let end = Date().addingTimeInterval(secs)
            while Date() < end { if (try? await js(cond)) == "true" { return }; try await Task.sleep(nanoseconds: 350_000_000) }
            throw JinnError("timed out waiting for \(what) in Gmail")
        }
        if (try? await Chrome.tabs().contains(tab)) != true {
            _ = try Shell.run("/usr/bin/open", ["-a", Chrome.appName, "https://mail.google.com"])
            try await wait("Gmail to load", "document.readyState==='complete'&&els().length>5", 25)
        }
        let busy = try await Interrupt.waitIdle(pid: Chrome.pid)
        // 1. open the thread (skip if it is already open and matches)
        if !find.isEmpty, (try await js("gThread()&&score(\(Chrome.jsString(find)),gTitle()+' '+txt(document.querySelector('[role=main]')).slice(0,400))>=.5")) != "true" {
            let r = try await js("clickT(\(Chrome.jsString(find)))")
            guard r.hasPrefix("clicked") else { throw JinnError("no email matching \"\(find)\" is visible in Gmail (\(r)). Open the right label/search first or use another sender or subject word") }
            try await wait("the thread to open", "gThread()")
        } else if find.isEmpty { try await wait("an open email", "gThread()", 3) }
        // 2. Reply, retrying: the button appears after the thread renders
        var reply = ""
        for _ in 0..<4 {
            reply = try await js("gReply(\(a.opt("all") == "true"))")
            if reply.hasPrefix("clicked"), (try? await wait("the compose box", "!!gBody()", 4)) != nil { break }
            reply = reply.hasPrefix("clicked") ? "compose box did not open" : reply
            try await Task.sleep(nanoseconds: 600_000_000)
        }
        guard (try await js("!!gBody()")) == "true" else { throw JinnError("could not open the reply box: \(reply)") }
        // 3. type and verify
        let typed = try await js("gType(\(Chrome.jsString(text)))")
        guard typed == "ok" else { throw JinnError("typing the reply failed: \(typed)") }
        guard a.opt("send") == "true" else { return "Reply written and left open in Gmail for review." + Interrupt.note(busy) }
        // 4. send and confirm the compose box closed
        let sent = try await js("gSend()")
        guard sent.hasPrefix("clicked") else { throw JinnError("typed the reply but \(sent)") }
        let closed = (try? await wait("the reply to send", "!gBody()", 6)) != nil
        return (closed ? "Reply sent." : "Pressed Send but the reply box is still open; ask the user to check Gmail.") + Interrupt.note(busy)
    },
]
