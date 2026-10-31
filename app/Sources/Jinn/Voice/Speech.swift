import AVFoundation

final class Speech {
    private let s = AVSpeechSynthesizer()
    func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        s.speak(u)
    }
    func stop() { s.stopSpeaking(at: .immediate) }
}
