import AppKit
import ApplicationServices
import AVFoundation
import Speech

/// Ask = confirm each action; Auto = run without asking (hard blocks in Safety still apply).
enum PermissionMode: String {
    case ask, auto
    static var current: PermissionMode { UserDefaults.standard.string(forKey: "permMode").flatMap(PermissionMode.init) ?? .ask }
}

/// macOS privacy permissions, asked once at the moment they matter instead of on every use.
enum Permissions {
    private static var openedAX = false

    static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)")!)
    }

    /// Shows the system prompt and opens the Accessibility pane. Safe to call repeatedly (the button in the HUD).
    static func askAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openSettings("Accessibility")
    }

    /// Message for the model when a tool needs Accessibility and it is off; prompts and opens Settings once per run.
    static func accessibilityGap(_ tool: Tool) -> String? {
        guard case .app = tool.risk, !AXIsProcessTrusted() else { return nil }
        if !openedAX { openedAX = true; askAccessibility() }
        return "error: Accessibility is off for Jinn. The HUD shows an Allow Accessibility button; tell the user to press it, switch Jinn on, and ask again."
    }

    /// Microphone + speech recognition: request only if never asked (a denied one is never re-prompted).
    static func requestVoice() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
    }

    /// nil when voice can run, else what to tell the user.
    static func voiceProblem() -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined: requestVoice(); return "Allow the microphone prompt, then press Option+Space again."
        default: openSettings("Microphone"); return "Microphone is off for Jinn. Turn it on in System Settings, then press Option+Space."
        }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return nil
        case .notDetermined: requestVoice(); return "Allow the speech recognition prompt, then press Option+Space again."
        default: openSettings("SpeechRecognition"); return "Speech Recognition is off for Jinn. Turn it on in System Settings."
        }
    }
}
