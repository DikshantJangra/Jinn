import AppKit

enum Interrupt {
    private static var last: [pid_t: Date] = [:]
    private static let lock = NSLock()
    static var tap: CFMachPort?

    static func touched(_ pid: pid_t, at t: Date = Date()) { lock.withLock { last[pid] = t } }
    static func lastTouch(_ pid: pid_t) -> Date { lock.withLock { last[pid] } ?? .distantPast }

    static func start() {
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, ev, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let t = Interrupt.tap { CGEvent.tapEnable(tap: t, enable: true) }
                } else if ev.getIntegerValueField(.eventSourceUserData) != Input.marker {
                    var pid = pid_t(ev.getIntegerValueField(.eventTargetUnixProcessID))
                    if pid == 0 { pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
                    Interrupt.touched(pid)
                }
                return Unmanaged.passUnretained(ev)
            }, userInfo: nil) else { return }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    }

    @discardableResult
    static func waitIdle(pid: pid_t, quiet: TimeInterval = 0.5, timeout: TimeInterval = 30) async throws -> Bool {
        let t0 = Date()
        var waited = false
        while Date().timeIntervalSince(lastTouch(pid)) < quiet {
            waited = true
            if Date().timeIntervalSince(t0) > timeout { throw JinnError("you are busy in that app; paused") }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return waited
    }

    static func note(_ interrupted: Bool) -> String { interrupted ? " (user was active in that app; re-check its state before the next action)" : "" }
}
