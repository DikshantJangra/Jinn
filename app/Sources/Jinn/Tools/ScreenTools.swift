import AppKit

private let appArg = ["app": "(optional) app name; default is the app in front"]

/// Clicks a screen point. `real` moves the visible cursor and clicks through the system (for apps that ignore background clicks).
private func clickPoint(_ p: CGPoint, app: NSRunningApplication, a: [String: Any]) async throws -> String {
    guard Screen.onScreen(p) else { throw JinnError("(\(Int(p.x)),\(Int(p.y))) is off screen") }
    // approval was for this app: the point must be inside its window, and for a real click nothing else may cover it
    guard let frame = Screen.windowFrame(app.processIdentifier), frame.contains(p) else { throw JinnError("point is outside \(app.localizedName ?? "the app")'s window") }
    if a.opt("real") == "true", Screen.ownerAt(p) != app.processIdentifier { throw JinnError("another window covers that point; nothing was clicked") }
    let right = a.opt("button") == "right", double = a.opt("double") == "true"
    if a.opt("real") == "true" {
        app.activate(options: [.activateIgnoringOtherApps])
        await Screen.glide(to: p)
        await Input.click(0, at: p, right: right, count: double ? 2 : 1)
    } else {
        await Input.click(app.processIdentifier, at: p, right: right, count: double ? 2 : 1)
    }
    return right ? "right-clicked" : double ? "double-clicked" : "clicked"
}

private let clickParams = ["button": "(optional) left or right", "double": "(optional) true for a double click",
                           "real": "(optional) true to move the visible cursor and click for real; use if a normal click did nothing"]

let screenTools: [Tool] = [
    Tool(name: "screen_ocr", description: "Read the text on an app's window by looking at its pixels (OCR). Returns each text line with its screen position x,y. Use when screen_read / app_state show few or no elements (canvas, games, images, remote desktops, some Electron apps).",
         params: appArg, risk: .app("app")) { a in
        let app = try Apps.target(a.opt("app"))
        let (region, items) = try await Screen.read(app)
        return "Window of \(app.localizedName ?? "app") at (\(Int(region.minX)),\(Int(region.minY))) size \(Int(region.width))x\(Int(region.height)). Positions are screen points.\n" + Screen.render(items)
    },

    Tool(name: "click_text", description: "Find text on an app's window by looking at the screen and click it. Works on anything visible, even when the app has no accessibility tree. Reports what changed afterwards.",
         params: appArg.merging(["text": "Text to find and click, as it appears on screen",
                                 "nth": "(optional) which match if several, 1 = topmost-leftmost"]) { $1 }.merging(clickParams) { $1 }, risk: .app("app")) { a in
        let app = try Apps.target(a.opt("app")), text = try a.str("text")
        let busy = try await Interrupt.waitIdle(pid: app.processIdentifier)
        let (_, items) = try await Screen.read(app)
        guard let (hit, total) = Screen.find(items, text, nth: Int(a.opt("nth")) ?? 1) else {
            throw JinnError("no text matching \"\(text)\" on screen. Visible text:\n" + Screen.render(items, budget: 1500))
        }
        let box = hit.target(text)
        let p = CGPoint(x: box.midX, y: box.midY)
        let how = try await clickPoint(p, app: app, a: a)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let after = (try? await Screen.read(app).items).map { Screen.diff(items, $0) } ?? "(could not read the result)"
        return "\(how) \"\(hit.text.prefix(60))\" at (\(Int(p.x)),\(Int(p.y)))" + (total > 1 ? " (\(total) matches; pass nth for another)" : "") + Interrupt.note(busy) + "\n" + after
    },

    Tool(name: "click_at", description: "Click an exact screen position x,y (screen points, as given by screen_ocr). Last resort when the target has no text or element.",
         params: appArg.merging(["x": "Screen x", "y": "Screen y"]) { $1 }.merging(clickParams) { $1 }, risk: .app("app")) { a in
        let app = try Apps.target(a.opt("app"))
        guard let x = Double(try a.str("x")), let y = Double(try a.str("y")) else { throw JinnError("x and y must be numbers") }
        let busy = try await Interrupt.waitIdle(pid: app.processIdentifier)
        let before = try? await Screen.read(app).items
        let how = try await clickPoint(CGPoint(x: x, y: y), app: app, a: a)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let after = (try? await Screen.read(app).items).flatMap { n in before.map { Screen.diff($0, n) } } ?? "(could not read the result)"
        return "\(how) (\(Int(x)),\(Int(y)))" + Interrupt.note(busy) + "\n" + after
    },

    Tool(name: "move_cursor", description: "Move the visible mouse cursor to a screen position (or onto on-screen text) without clicking, e.g. to trigger a hover menu or tooltip.",
         params: appArg.merging(["x": "(optional) Screen x", "y": "(optional) Screen y", "text": "(optional) on-screen text to move onto, instead of x,y"]) { $1 }, risk: .app("app")) { a in
        let app = try Apps.target(a.opt("app"))
        var p: CGPoint
        if let x = Double(a.opt("x")), let y = Double(a.opt("y")) { p = CGPoint(x: x, y: y) }
        else {
            let text = try a.str("text")
            guard let (hit, _) = Screen.find(try await Screen.read(app).items, text) else { throw JinnError("no text matching \"\(text)\" on screen") }
            let b = hit.target(text); p = CGPoint(x: b.midX, y: b.midY)
        }
        guard Screen.onScreen(p) else { throw JinnError("(\(Int(p.x)),\(Int(p.y))) is off screen") }
        await Screen.glide(to: p)
        return "cursor at (\(Int(p.x)),\(Int(p.y)))"
    },

    Tool(name: "wait_for_text", description: "Wait until some text appears on an app's window (a page finished loading, a dialog opened). Returns when found or after the timeout.",
         params: appArg.merging(["text": "Text to wait for", "seconds": "(optional) max wait, default 10, max 30"]) { $1 }, risk: .app("app")) { a in
        let app = try Apps.target(a.opt("app")), text = try a.str("text")
        let limit = min(30, max(1, Double(a.opt("seconds")) ?? 10)), start = Date()
        while Date().timeIntervalSince(start) < limit {
            if let items = try? await Screen.read(app).items, let (hit, _) = Screen.find(items, text) {
                return "found \"\(hit.text.prefix(60))\" at (\(Int(hit.center.x)),\(Int(hit.center.y))) after \(Int(Date().timeIntervalSince(start)))s"
            }
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        throw JinnError("\"\(text)\" did not appear within \(Int(limit))s")
    },
]
