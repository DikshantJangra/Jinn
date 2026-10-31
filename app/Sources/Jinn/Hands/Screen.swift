import AppKit
import Vision

struct Seen {
    let text: String
    let rect: CGRect
    var cand: VNRecognizedText? = nil
    var region: CGRect = .zero

    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }

    func target(_ query: String) -> CGRect {
        guard let cand, let r = text.range(of: query, options: .caseInsensitive), let b = try? cand.boundingBox(for: r) else { return rect }
        return Screen.globalRect(b.boundingBox, in: region)
    }
}

enum Screen {
    static func globalRect(_ n: CGRect, in region: CGRect) -> CGRect {
        CGRect(x: region.minX + n.minX * region.width, y: region.minY + (1 - n.maxY) * region.height,
               width: n.width * region.width, height: n.height * region.height)
    }

    static func find(_ items: [Seen], _ query: String, nth: Int = 1) -> (hit: Seen, total: Int)? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let exact = items.filter { $0.text.lowercased() == q }
        let hits = exact.isEmpty ? items.filter { $0.text.lowercased().contains(q) } : exact
        guard hits.indices.contains(nth - 1) else { return nil }
        return (hits[nth - 1], hits.count)
    }

    static func windowFrame(_ pid: pid_t) -> CGRect? { window(pid)?.frame }

    /// Window server id + bounds of the app's front window.
    static func window(_ pid: pid_t) -> (id: Int, frame: CGRect)? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? [String: CGFloat], let wd = b["Width"], let ht = b["Height"], wd > 50, ht > 50 {
                return (w[kCGWindowNumber as String] as? Int ?? 0, CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: wd, height: ht))
            }
        }
        return nil
    }

    static func ownerAt(_ p: CGPoint) -> pid_t? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? [String: CGFloat],
               CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(p) {
                return w[kCGWindowOwnerPID as String] as? pid_t
            }
        }
        return nil
    }

    static func capture(_ r: CGRect, windowID: Int = 0) throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw JinnError.permission("Screen Recording")
        }
        let path = NSTemporaryDirectory() + "jinn-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        // the window itself (-l, no shadow): Jinn's own lamp and anything covering it never end up in the OCR
        if windowID == 0 || (try? Shell.run("/usr/sbin/screencapture", ["-x", "-o", "-t", "png", "-l", "\(windowID)", path], timeout: 10)) == nil {
            _ = try Shell.run("/usr/sbin/screencapture", ["-x", "-t", "png", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", path], timeout: 10)
        }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw JinnError("screenshot failed") }
        return img
    }

    static func read(_ app: NSRunningApplication) async throws -> (region: CGRect, items: [Seen]) {
        guard let win = window(app.processIdentifier) else { throw JinnError("\(app.localizedName ?? "app") has no visible window to read") }
        let region = win.frame
        let img = try capture(region, windowID: win.id)
        let items = try await Task.detached { () -> [Seen] in
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: img).perform([req])
            return (req.results ?? []).compactMap { o in
                guard let c = o.topCandidates(1).first, !c.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return Seen(text: c.string, rect: globalRect(o.boundingBox, in: region), cand: c, region: region)
            }
        }.value
        let rows = items.sorted { abs($0.rect.minY - $1.rect.minY) > 6 ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
        return (region, rows)
    }

    static func render(_ items: [Seen], budget: Int = 5000) -> String {
        var used = 0, out: [String] = []
        for s in items {
            let l = "\"\(s.text.prefix(90))\" @\(Int(s.center.x)),\(Int(s.center.y))"
            if used + l.count > budget { out.append("… more text truncated"); break }
            used += l.count + 1; out.append(l)
        }
        return out.isEmpty ? "(no text recognised)" : out.joined(separator: "\n")
    }

    static func diff(_ old: [Seen], _ new: [Seen]) -> String {
        let a = Set(old.map(\.text)), b = Set(new.map(\.text))
        let lines = b.subtracting(a).sorted().prefix(8).map { "+ \"\($0.prefix(60))\"" } + a.subtracting(b).sorted().prefix(4).map { "- \"\($0.prefix(60))\"" }
        return lines.isEmpty ? "No visible change (the click may not have taken effect)." : "Changed:\n" + lines.joined(separator: "\n")
    }

    static func glide(to p: CGPoint) async {
        let from = CGEvent(source: nil)?.location ?? p
        for i in 1...12 {
            let t = Double(i) / 12, q = CGPoint(x: from.x + (p.x - from.x) * t, y: from.y + (p.y - from.y) * t)
            CGWarpMouseCursorPosition(q)
            if let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: q, mouseButton: .left) {
                e.setIntegerValueField(.eventSourceUserData, value: Input.marker)
                e.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
    }

    static func onScreen(_ p: CGPoint) -> Bool {
        var id: CGDirectDisplayID = 0, n: UInt32 = 0
        return CGGetDisplaysWithPoint(p, 1, &id, &n) == .success && n > 0
    }
}
