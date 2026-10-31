import AppKit

enum Input {
    static let marker: Int64 = 0x4A494E4E
    private static let src = CGEventSource(stateID: .privateState)
    private static var eventNumber: Int64 = 0

    private static func post(_ e: CGEvent, _ pid: pid_t) {
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        if pid == 0 { e.post(tap: .cghidEventTap) } else { e.postToPid(pid) }
    }

    static func key(_ pid: pid_t, _ code: CGKeyCode, flags: CGEventFlags = []) async {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            post(e, pid)
            try? await Task.sleep(nanoseconds: down ? 8_000_000 : 3_000_000)
        }
    }

    private static func unicode(_ pid: pid_t, _ c: Character) async {
        let u = Array(String(c).utf16)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
            e.flags = []
            e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
            post(e, pid)
            try? await Task.sleep(nanoseconds: down ? 8_000_000 : 3_000_000)
        }
    }

    static func type(_ pid: pid_t, _ text: String) async {
        for c in text {
            if let k = Keys.forChar(c) { await key(pid, k.code, flags: k.flags) } else { await unicode(pid, c) }
        }
    }

    static func windowID(_ pid: pid_t, at p: CGPoint) -> Int64? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String] as? [String: CGFloat],
               CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(p) {
                return (w[kCGWindowNumber as String] as? Int64) ?? (w[kCGWindowNumber as String] as? Int).map(Int64.init)
            }
        }
        return nil
    }

    static func click(_ pid: pid_t, at p: CGPoint, right: Bool = false, count: Int = 1) async {
        let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        let win = windowID(pid, at: p)
        for n in 1...count {
            if n > 1 { try? await Task.sleep(nanoseconds: 100_000_000) }
            for t in [down, up] {
                guard let e = CGEvent(mouseEventSource: src, mouseType: t, mouseCursorPosition: p, mouseButton: btn) else { continue }
                eventNumber += 1
                e.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                e.setIntegerValueField(.mouseEventNumber, value: eventNumber)
                e.setDoubleValueField(.mouseEventPressure, value: t == down ? 1 : 0)
                if let win {
                    e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: win)
                    e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: win)
                }
                post(e, pid)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    static func scroll(_ pid: pid_t, at p: CGPoint, dy: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return }
        e.location = p
        post(e, pid)
    }
}
