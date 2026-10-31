// Copied from Agent! (https://github.com/macos26/Agent) Agent/Services/ShellSafetyService.swift
// Required Notice: Copyright (c) 2026 AgentiLoop.ai, a Logos InkPen LLC company (https://AgentiLoop.ai)
// Licensed under the PolyForm Noncommercial License 1.0.0 (https://polyformproject.org/licenses/noncommercial/1.0.0).
// This file is NOT covered by Jinn's MIT license: noncommercial use only. Remove it (and the call in Safety.swift)
// before any commercial use of Jinn. Modified: "Agent!" in user-facing messages renamed to "Jinn".
import Foundation

enum ShellSafetyService {

    enum Context {
        case userAgent
        case rootDaemon
    }

    struct Verdict {
        let allowed: Bool
        let reason: String?
        let rule: String?

        static let ok = Verdict(allowed: true, reason: nil, rule: nil)

        static func block(reason: String, rule: String) -> Verdict {
            Verdict(allowed: false, reason: reason, rule: rule)
        }
    }

    static func check(_ command: String, context: Context = .userAgent, projectFolder: String = "") -> Verdict {
        if context == .rootDaemon {
            for segment in splitOnShellSeparators(command) {
                let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if let v = checkCatastrophicRm(trimmed, projectFolder: projectFolder), !v.allowed { return v }
            }
            return .ok
        }

        let forkVerdict = checkForkBomb(command)
        if !forkVerdict.allowed { return forkVerdict }

        for segment in splitOnShellSeparators(command) {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let verdict = checkSingleSegment(trimmed, context: context, projectFolder: projectFolder)
            if !verdict.allowed { return verdict }
        }
        return .ok
    }

    private static func checkCatastrophicRm(_ command: String, projectFolder: String) -> Verdict? {
        let stripped = stripPrefixWrappers(command)
        let tokens = tokenize(stripped)
        guard let rmIdx = tokens.firstIndex(of: "rm") else { return nil }

        var hasR = false
        var hasF = false
        var positionals: [String] = []
        var i = rmIdx + 1
        while i < tokens.count {
            let t = tokens[i]
            if t == "--recursive" { hasR = true }
            else if t == "--force" { hasF = true }
            else if t == "--no-preserve-root" {
                return .block(
                    reason: "Refused: `rm --no-preserve-root` is the explicit bypass for `/` protection. Blocked even via the root daemon.",
                    rule: "rm.no-preserve-root"
                )
            }
            else if t.hasPrefix("--") {
            } else if t.hasPrefix("-") && t.count >= 2 {
                let chars = t.dropFirst()
                if chars.contains("r") || chars.contains("R") { hasR = true }
                if chars.contains("f") || chars.contains("F") { hasF = true }
            } else {
                positionals.append(t)
            }
            i += 1
        }
        guard hasR && hasF else { return nil }

        for target in positionals {
            if let reason = catastrophicRmReason(target) {
                return .block(
                    reason: "Refused: `rm -rf \(target)` — \(reason). This is one of the three patterns blocked even from the root daemon.",
                    rule: "rm.catastrophic"
                )
            }
            if let reason = projectFolderWipeReason(target, projectFolder: projectFolder) {
                return .block(
                    reason: "Refused: `rm -rf \(target)` — \(reason). Blocked even via the root daemon.",
                    rule: "rm.project-folder"
                )
            }
        }
        return nil
    }

    private static func catastrophicRmReason(_ target: String) -> String? {
        var t = target
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }
        if t == "/" || t == "/*" || t == "/.*" || t == "/." || t == "/.." {
            return "this would erase the entire filesystem"
        }
        if t == "*" || t == "*.*" || t == "./*" || t == ".*" {
            return "this glob expands to every file in the current directory, which could be anywhere"
        }
        let homeForms: Set<String> = [
            "~", "~/", "~/*", "~/.*",
            "$HOME", "${HOME}", "$HOME/", "${HOME}/",
            "$HOME/*", "${HOME}/*", "$HOME/.*", "${HOME}/.*",
        ]
        if homeForms.contains(t) {
            return "this is your home directory"
        }
        let realHome = NSHomeDirectory()
        if t == realHome || t == realHome + "/" || t == realHome + "/*" {
            return "this is your home directory"
        }
        return nil
    }

    private static func checkSingleSegment(_ command: String, context: Context, projectFolder: String) -> Verdict {
        _ = context

        let stripped = stripPrefixWrappers(command)
        let tokens = tokenize(stripped)
        if tokens.isEmpty { return .ok }

        if let v = checkDangerousRm(tokens: tokens, projectFolder: projectFolder), !v.allowed { return v }

        if let v = checkFindDelete(tokens: tokens), !v.allowed { return v }

        if let v = checkRecursivePermsOnRoot(tokens: tokens), !v.allowed { return v }

        if let v = checkMoveToDevNull(tokens: tokens), !v.allowed { return v }

        return .ok
    }

    private static func checkDangerousRm(tokens: [String], projectFolder: String) -> Verdict? {
        guard let rmIdx = tokens.firstIndex(of: "rm") else { return nil }
        var hasR = false
        var hasF = false
        var positionals: [String] = []

        var i = rmIdx + 1
        while i < tokens.count {
            let t = tokens[i]
            if t == "--recursive" || t == "--Recursive" { hasR = true }
            else if t == "--force" { hasF = true }
            else if t == "--no-preserve-root" {
                return .block(
                    reason: "Refused: `rm --no-preserve-root` is only used to bypass macOS/GNU's safeguard against deleting `/`. This command is permanently disabled in Jinn.",
                    rule: "rm.no-preserve-root"
                )
            }
            else if t.hasPrefix("--") {
            } else if t.hasPrefix("-") && t.count >= 2 {
                let chars = t.dropFirst()
                if chars.contains("r") || chars.contains("R") { hasR = true }
                if chars.contains("f") || chars.contains("F") { hasF = true }
            } else {
                positionals.append(t)
            }
            i += 1
        }

        guard hasR && hasF else { return nil }

        for target in positionals {
            if let reason = dangerousRmTargetReason(target) {
                return .block(
                    reason: "Refused: `rm -rf \(target)` — \(reason). Jinn blocks this pattern locally before it reaches any shell. Narrow the path to a specific subdirectory you actually want to delete.",
                    rule: "rm.dangerous-target"
                )
            }
            if let reason = projectFolderWipeReason(target, projectFolder: projectFolder) {
                return .block(
                    reason: "Refused: `rm -rf \(target)` — \(reason). Jinn blocks this locally before it reaches any shell. Delete specific files or subdirectories instead.",
                    rule: "rm.project-folder"
                )
            }
        }
        return nil
    }

    private static func projectFolderWipeReason(_ target: String, projectFolder: String) -> String? {
        let trimmed = projectFolder.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var t = target
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }
        let expanded = (t as NSString).expandingTildeInPath
        let folder = (trimmed as NSString).expandingTildeInPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalized = expanded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !folder.isEmpty, !normalized.isEmpty else { return nil }

        if normalized == folder
            || normalized == folder + "/*"
            || normalized == folder + "/.*"
            || normalized == folder + "/**" {
            return "this would wipe the current project folder (\(folder))"
        }
        return nil
    }

    private static func dangerousRmTargetReason(_ target: String) -> String? {
        var t = target
        if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
            t = String(t.dropFirst().dropLast())
        }

        if t == "*" || t == "*.*" || t == "." || t == ".." || t == "./*" || t == "./" || t == ".*" {
            return "this glob/relative path is too broad — the working directory could be `/` or `~`"
        }

        if t == "/" || t == "/*" || t == "/.*" || t == "/." || t == "/.." {
            return "this would erase the entire filesystem"
        }

        let systemRoots: Set<String> = [
            "/etc", "/usr", "/bin", "/sbin", "/var", "/lib", "/lib64",
            "/boot", "/proc", "/sys", "/dev", "/run", "/opt",
            "/System", "/Library", "/Applications", "/private",
            "/Volumes", "/Network", "/cores", "/Users", "/home",
        ]
        for root in systemRoots {
            if t == root || t == root + "/" || t == root + "/*" || t == root + "/.*" {
                return "this is a critical system directory"
            }
        }

        let homeForms: Set<String> = [
            "~", "~/", "~/*", "~/.*",
            "$HOME", "${HOME}", "$HOME/", "${HOME}/",
            "$HOME/*", "${HOME}/*", "$HOME/.*", "${HOME}/.*",
        ]
        if homeForms.contains(t) {
            return "this is your home directory"
        }

        let realHome = NSHomeDirectory()
        if t == realHome || t == realHome + "/" || t == realHome + "/*" {
            return "this is your home directory"
        }

        return nil
    }

    private static func checkFindDelete(tokens: [String]) -> Verdict? {
        guard tokens.contains("-delete") else { return nil }
        guard let findIdx = tokens.firstIndex(of: "find") else { return nil }
        if findIdx + 1 < tokens.count {
            let root = tokens[findIdx + 1]
            if dangerousRmTargetReason(root) != nil {
                return .block(
                    reason: "Refused: `find \(root) ... -delete` — `find -delete` recursively removes everything matching the predicates and the search root is too broad. Narrow the search root.",
                    rule: "find.delete-broad-root"
                )
            }
        }
        return nil
    }

    private static func checkRecursivePermsOnRoot(tokens: [String]) -> Verdict? {
        guard let cmdIdx = tokens.firstIndex(where: { $0 == "chmod" || $0 == "chown" }) else { return nil }
        let cmd = tokens[cmdIdx]
        var recursive = false
        var positionals: [String] = []
        for j in (cmdIdx + 1)..<tokens.count {
            let t = tokens[j]
            if t == "-R" || t == "--recursive" {
                recursive = true
            } else if t.hasPrefix("-") {
                if t.dropFirst().contains("R") { recursive = true }
            } else {
                positionals.append(t)
            }
        }
        guard recursive else { return nil }
        for target in positionals {
            if dangerousRmTargetReason(target) != nil {
                return .block(
                    reason: "Refused: `\(cmd) -R ... \(target)` — recursively changing permissions/ownership on a system root will brick the OS or your account. Narrow the target.",
                    rule: "perms.recursive-on-root"
                )
            }
        }
        return nil
    }

    private static func checkForkBomb(_ command: String) -> Verdict {
        let collapsed = command.replacingOccurrences(of: " ", with: "")
        if collapsed.contains(":(){:|:&};:") || collapsed.contains(":(){:|:&};:&") {
            return .block(
                reason: "Refused: classic fork bomb. This recursively spawns processes until the kernel runs out of process slots and the machine becomes unresponsive.",
                rule: "fork-bomb"
            )
        }
        return .ok
    }

    private static func checkMoveToDevNull(tokens: [String]) -> Verdict? {
        guard tokens.first == "mv" else { return nil }
        guard tokens.contains("/dev/null") else { return nil }
        let positionals = tokens.dropFirst().filter { !$0.hasPrefix("-") }
        for t in positionals.dropLast() {
            if dangerousRmTargetReason(t) != nil {
                return .block(
                    reason: "Refused: moving `\(t)` to `/dev/null` is equivalent to deleting it permanently.",
                    rule: "mv.to-devnull"
                )
            }
        }
        return nil
    }

    private static let readOnlyVerbs: Set<String> = [
        "ls", "cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "ag",
        "find", "fd", "wc", "echo", "printf", "pwd", "which", "whereis", "type", "file",
        "stat", "du", "df", "date", "uname", "sw_vers", "env", "printenv", "id", "whoami",
        "hostname", "basename", "dirname", "realpath", "readlink", "md5", "shasum", "cksum",
        "sort", "uniq", "cut", "tr", "awk", "jq", "tree", "diff", "cmp", "strings", "nl",
        "column", "fold", "true", "test", "[", "git", "swift", "xcodebuild", "xcrun", "plutil",
        "defaults", "sysctl", "ps", "lsof", "ioreg", "system_profiler", "mdfind", "mdls",
    ]
    private static let readOnlyGitSubcommands: Set<String> = [
        "status", "log", "diff", "show", "branch", "rev-parse", "ls-files", "blame",
        "describe", "remote", "tag", "stash", "shortlog", "grep", "cat-file", "config",
    ]

    static func isReadOnly(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("$(") || trimmed.contains("`") || trimmed.contains("<<") { return false }
        for rawSegment in splitOnShellSeparators(trimmed) {
            let segment = stripPrefixWrappers(rawSegment)
            if segment.hasSuffix("&") { return false }
            let withoutRedirects = segment
                .replacingOccurrences(of: "2>&1", with: "")
                .replacingOccurrences(of: "&>/dev/null", with: "")
            if withoutRedirects.contains("&") { return false }
            let tokens = tokenize(segment)
            guard let verb = tokens.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            guard readOnlyVerbs.contains(verb) else { return false }
            for t in tokens where t.contains(">") {
                guard t == "2>/dev/null" || t == "2>&1" || t == ">/dev/null" || t == "&>/dev/null" else { return false }
            }
            switch verb {
            case "git":
                guard let sub = tokens.dropFirst().first(where: { !$0.hasPrefix("-") }),
                      readOnlyGitSubcommands.contains(sub) else { return false }
                if sub == "stash" && !(tokens.count > 2 && (tokens[2] == "list" || tokens[2] == "show")) { return false }
                if sub == "branch" && tokens.contains(where: { $0 == "-d" || $0 == "-D" || $0 == "-m" || $0 == "-M" }) { return false }
                if sub == "remote" && tokens.count > 2 && tokens[2] != "-v" && tokens[2] != "show" { return false }
                if sub == "tag" && tokens.count > 2 && !tokens[2].hasPrefix("-l") { return false }
                if sub == "config" && !tokens.contains(where: { $0 == "--get" || $0 == "--list" || $0 == "-l" }) { return false }
            case "find", "fd":
                if tokens.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-x", "-X"].contains($0) }) { return false }
            case "swift":
                guard tokens.count > 1, tokens[1] == "--version" || tokens[1] == "-version" else { return false }
            case "xcodebuild":
                guard tokens.contains(where: { $0 == "-list" || $0 == "-showsdks" || $0 == "-version" || $0 == "-showBuildSettings" }) else { return false }
            case "xcrun":
                guard tokens.count > 1, tokens[1] == "--find" || tokens[1] == "--show-sdk-path" || (tokens[1] == "simctl" && tokens.contains("list")) else { return false }
            case "plutil":
                guard tokens.contains("-p") || tokens.contains("-lint") else { return false }
            case "defaults":
                guard tokens.count > 1, tokens[1] == "read" else { return false }
            case "sysctl":
                if tokens.contains("-w") { return false }
            default:
                break
            }
        }
        return true
    }

    private static func stripPrefixWrappers(_ command: String) -> String {
        var result = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["sudo ", "exec ", "command ", "builtin ", "eval ", "doas "]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where result.lowercased().hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
            if let space = result.firstIndex(of: " "),
               result[..<space].contains("="),
               !result[..<space].contains("/")
            {
                result = String(result[result.index(after: space)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return result
    }

    private static func tokenize(_ command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var escape = false
        for ch in command {
            if escape {
                current.append(ch)
                escape = false
                continue
            }
            if ch == "\\" {
                current.append(ch)
                escape = true
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
                current.append(ch)
                continue
            }
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                current.append(ch)
                continue
            }
            if (ch == " " || ch == "\t") && !inSingle && !inDouble {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func splitOnShellSeparators(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var i = command.startIndex
        while i < command.endIndex {
            let ch = command[i]
            if ch == "'" && !inDouble { inSingle.toggle(); current.append(ch); i = command.index(after: i); continue }
            if ch == "\"" && !inSingle { inDouble.toggle(); current.append(ch); i = command.index(after: i); continue }
            if !inSingle && !inDouble {
                let next = command.index(after: i)
                if next < command.endIndex {
                    let two = String(command[i...next])
                    if two == "&&" || two == "||" {
                        if !current.isEmpty { segments.append(current); current = "" }
                        i = command.index(after: next)
                        continue
                    }
                }
                if ch == ";" || ch == "|" || ch == "\n" {
                    if !current.isEmpty { segments.append(current); current = "" }
                    i = command.index(after: i)
                    continue
                }
            }
            current.append(ch)
            i = command.index(after: i)
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }
}
