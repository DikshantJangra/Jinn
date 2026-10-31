import AppKit
import ApplicationServices
import AVFoundation
import Speech

enum PermissionMode: String {
    case ask, auto
    static var current: PermissionMode { UserDefaults.standard.string(forKey: "permMode").flatMap(PermissionMode.init) ?? .ask }
}

enum Permissions {
    private static var openedAX = false

    static func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)")!)
    }

    static func askAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openSettings("Accessibility")
    }

    static func accessibilityGap(_ tool: Tool) -> String? {
        guard case .app = tool.risk, !AXIsProcessTrusted() else { return nil }
        if !openedAX { openedAX = true; askAccessibility() }
        return "error: Accessibility is off for Jinn. The HUD shows an Allow Accessibility button; tell the user to press it, switch Jinn on, and ask again."
    }

    static func requestVoice() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
    }

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
