import Foundation

let shellTools: [Tool] = [
    Tool(name: "run_shell", description: "Run a zsh command in the user's home folder (30s limit). For anything the other tools cannot do. The user approves every command.",
         params: ["command": "The shell command line"], risk: .confirm,
         vet: { a in if case .block(let why) = Safety.shell(a.opt("command")) { return why } else { return nil } }) { a in
        let cmd = try a.str("command")
        if case .block(let why) = Safety.shell(cmd) { throw JinnError.blocked(why) }
        return try Shell.sh(cmd)
    },
]
