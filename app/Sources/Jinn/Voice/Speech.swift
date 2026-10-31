import AVFoundation

final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    private let s = AVSpeechSynthesizer()
    var onChange: (Bool) -> Void = { _ in }

    override init() { super.init(); s.delegate = self }

    func say(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        s.speak(u)
    }
    func stop() { s.stopSpeaking(at: .immediate) }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) { DispatchQueue.main.async { self.onChange(true) } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { DispatchQueue.main.async { self.onChange(false) } }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { DispatchQueue.main.async { self.onChange(false) } }
}
