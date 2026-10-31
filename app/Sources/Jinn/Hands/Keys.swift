import CoreGraphics

enum Keys {
    private static let map: [String: (CGKeyCode, CGEventFlags)] = {
        var m: [String: (CGKeyCode, CGEventFlags)] = [:]
        func reg(_ names: [String], _ code: CGKeyCode, _ flags: CGEventFlags = []) { for n in names { m[n.lowercased()] = (code, flags) } }
        let letters: [CGKeyCode] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (i, c) in letters.enumerated() { reg([String(UnicodeScalar(UInt8(97 + i)))], c) }
        let digits: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (i, c) in digits.enumerated() { reg([String(i)], c) }
        for (i, ch) in [")", "!", "@", "#", "$", "%", "^", "&", "*", "("].enumerated() { reg([ch], digits[i], .maskShift) }
        let f: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, c) in f.enumerated() { reg(["f\(i + 1)"], c) }
        reg(["return", "enter"], 36); reg(["tab"], 48); reg(["space"], 49)
        reg(["backspace", "delete", "back_space"], 51); reg(["escape", "esc"], 53)
        reg(["left"], 123); reg(["right"], 124); reg(["down"], 125); reg(["up"], 126)
        reg(["home"], 115); reg(["end"], 119); reg(["page_up", "pageup", "prior"], 116); reg(["page_down", "pagedown", "next"], 121)
        reg(["forwarddelete", "forward_delete"], 117)
        reg(["minus", "-"], 27); reg(["_"], 27, .maskShift); reg(["equal", "="], 24); reg(["plus"], 24, .maskShift)
        reg(["bracketleft", "bracket_left", "["], 33); reg(["{"], 33, .maskShift)
        reg(["bracketright", "bracket_right", "]"], 30); reg(["}"], 30, .maskShift)
        reg(["semicolon", ";"], 41); reg([":"], 41, .maskShift)
        reg(["apostrophe", "quote", "'"], 39); reg(["\""], 39, .maskShift)
        reg(["comma", ","], 43); reg(["<"], 43, .maskShift)
        reg(["period", "."], 47); reg([">"], 47, .maskShift)
        reg(["slash", "/"], 44); reg(["?"], 44, .maskShift)
        reg(["backslash", "\\"], 42); reg(["|"], 42, .maskShift)
        reg(["grave", "`"], 50); reg(["asciitilde", "~"], 50, .maskShift)
        reg(["volumeup", "volume_up"], 72); reg(["volumedown", "volume_down"], 73); reg(["mute"], 74)
        return m
    }()

    private static let mods: [String: CGEventFlags] = [
        "cmd": .maskCommand, "command": .maskCommand, "super": .maskCommand, "meta": .maskCommand,
        "ctrl": .maskControl, "control": .maskControl,
        "alt": .maskAlternate, "option": .maskAlternate, "opt": .maskAlternate,
        "shift": .maskShift,
    ]

    static func parse(_ combo: String) throws -> (code: CGKeyCode, flags: CGEventFlags) {
        let parts = combo == "+" ? ["plus"] : combo.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        var flags: CGEventFlags = []
        var key: (CGKeyCode, CGEventFlags)?
        for part in parts {
            if let f = mods[part.lowercased()] { flags.insert(f); continue }
            guard key == nil else { throw JinnError("'\(combo)' has more than one non-modifier key") }
            guard let k = map[part.lowercased()] else {
                throw JinnError("unknown key '\(part)' in '\(combo)' (examples: Return, Tab, cmd+a, ctrl+Left, shift+Tab)")
            }
            key = k
            if part.count == 1, part.first!.isLetter, part.first!.isUppercase { flags.insert(.maskShift) }
        }
        guard let key else { throw JinnError("no non-modifier key in '\(combo)'") }
        return (key.0, flags.union(key.1))
    }

    static func forChar(_ c: Character) -> (code: CGKeyCode, flags: CGEventFlags)? {
        switch c {
        case " ": return try? parse("space")
        case "\n", "\r": return try? parse("return")
        case "\t": return try? parse("tab")
        case "+": return try? parse("plus")
        default:
            guard c.isASCII, !c.isWhitespace else { return nil }
            return try? parse(String(c))
        }
    }
}
