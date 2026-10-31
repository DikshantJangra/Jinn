import AVFoundation
import Speech

/// On-device speech-to-text via Apple's Speech framework (no extra dependency, no network when the model supports it).
final class Dictation {
    private let engine = AVAudioEngine()
    private let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var req: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var _latest = ""
    private let lock = NSLock()
    private var latest: String { get { lock.withLock { _latest } } set { lock.withLock { _latest = newValue } } }

    func start() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        latest = ""
        // no mic access or no input device gives a 0 Hz format, and installTap then raises an uncatchable ObjC exception
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        }
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        if rec?.supportsOnDeviceRecognition == true { r.requiresOnDeviceRecognition = true }
        req = r
        task = rec?.recognitionTask(with: r) { [weak self] res, _ in
            if let t = res?.bestTranscription.formattedString { self?.latest = t }
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in r.append(buf) }
        engine.prepare()
        try? engine.start()
    }

    func cancel() {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); req = nil; task = nil
    }

    func stop() async -> String {
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        req?.endAudio()
        try? await Task.sleep(nanoseconds: 800_000_000) // ponytail: fixed wait for the last partial; await isFinal if tails get clipped
        task?.cancel(); req = nil; task = nil
        return latest
    }
}
