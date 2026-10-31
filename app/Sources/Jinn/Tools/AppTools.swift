import Foundation

let appTools: [Tool] = [
    Tool(name: "open_app", description: "Open a Mac app by name, e.g. WhatsApp, Mail, Safari. Brought to front unless background is true.",
         params: ["name": "App name", "background": "(optional) true to launch without taking focus, when you only need to drive it"]) { a in
        let name = try a.str("name")
        try Apps.launch(name, background: a.opt("background") == "true")
        for _ in 0..<25 where (try? Apps.resolve(name)) == nil { try await Task.sleep(nanoseconds: 200_000_000) }
        return "Opened \(name)."
    },
    Tool(name: "read_unread_mail", description: "List unread emails in Apple Mail (sender and subject)") { _ in
        let out = try AppleScript.run("""
        tell application "Mail"
          set out to ""
          repeat with m in (messages of inbox whose read status is false)
            set out to out & (sender of m) & " | " & (subject of m) & linefeed
            if (length of out) > 3000 then exit repeat
          end repeat
          return out
        end tell
        """)
        return out.isEmpty ? "No unread mail." : out
    },
    Tool(name: "draft_mail", description: "Open a new draft email in Mail. Does not send.",
         params: ["to": "Recipient email address", "subject": "Subject line", "body": "Message body"]) { a in
        try AppleScript.run("""
        tell application "Mail"
          set m to make new outgoing message with properties {subject:"\(AppleScript.esc(try a.str("subject")))", content:"\(AppleScript.esc(try a.str("body")))", visible:true}
          tell m to make new to recipient at end of to recipients with properties {address:"\(AppleScript.esc(try a.str("to")))"}
        end tell
        """)
        return "Draft opened in Mail."
    },
    Tool(name: "send_message", description: "Send an iMessage/SMS via the Messages app",
         params: ["to": "Phone number with country code or Apple ID email", "text": "Message text"], risk: .confirm, alwaysAsk: true) { a in
        try AppleScript.run("""
        tell application "Messages"
          set s to 1st account whose service type = iMessage
          send "\(AppleScript.esc(try a.str("text")))" to participant "\(AppleScript.esc(try a.str("to")))" of s
        end tell
        """)
        return "Sent."
    },
]
