/// Operational hints per app bundle id, appended to app_state so a small model knows each app's quirks.
let appGuidance: [String: String] = [
    "net.whatsapp.whatsapp": "Select a chat in the sidebar first, then set_value on the message field and click Send. Search is the top field.",
    "com.apple.mail": "Prefer read_unread_mail / draft_mail tools over driving the UI.",
    "com.apple.finder": "Prefer the file tools over driving Finder.",
    "com.google.chrome": "Web pages are best handled with chrome_read_form / chrome_fill_form. Use the AX tree only for browser chrome (tabs, address bar).",
    "com.apple.safari": "set_value on the address field then press_key Return to navigate.",
    "com.apple.notes": "set_value on the note body replaces all text; use type_text to append.",
]
