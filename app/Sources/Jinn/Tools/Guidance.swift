let appGuidance: [String: String] = [
    "net.whatsapp.whatsapp": "To message someone: app_state, click the Search field (or press_key cmd+f), type_text the contact name, click the matching chat, app_state again. Then type_text the message into the message box and press_key Return only after the user has confirmed the text. If set_value fails, use type_text.",
    "com.apple.mail": "Prefer read_unread_mail / draft_mail tools over driving the UI.",
    "com.apple.finder": "Prefer the file tools over driving Finder.",
    "com.google.chrome": "Web pages are best handled with chrome_read_form / chrome_fill_form. Use the AX tree only for browser chrome (tabs, address bar).",
    "com.apple.safari": "set_value on the address field then press_key Return to navigate.",
    "com.apple.notes": "set_value on the note body replaces all text; use type_text to append.",
]
