import AVFoundation
import Speech

final class Dictation {
    private let engine = AVAudioEngine()
    private let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var req: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var _latest = ""
    private let lock = NSLock()
    private var latest: String { get { lock.withLock { _latest } } set { lock.withLock { _latest = newValue } } }

    /// Fires once when you stop talking (or never start): the caller then finishes the recording as if you clicked again.
    var onAutoStop: (() -> Void)?
    private var lastActivity = Date(), started = Date()
    private var timer: DispatchSourceTimer?
    private var activity: Date { get { lock.withLock { lastActivity } } set { lock.withLock { lastActivity = newValue } } }
    private let quiet: TimeInterval = 1.4      // silence after speech that ends the recording
    private let noSpeech: TimeInterval = 8     // nothing said at all
    private let longest: TimeInterval = 60

    private func startWatching() {
        started = Date(); activity = Date()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date(), spoke = !self.latest.isEmpty
            if (spoke && now.timeIntervalSince(self.activity) > self.quiet) || (!spoke && now.timeIntervalSince(self.started) > self.noSpeech) || now.timeIntervalSince(self.started) > self.longest {
                self.stopWatching(); self.onAutoStop?()
            }
        }
        timer = t; t.resume()
    }
    private func stopWatching() { timer?.cancel(); timer = nil }

    func start() -> String? {
        if let problem = Permissions.voiceProblem() { return problem }
        latest = ""
        let fmt = engine.inputNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return "No microphone found." }
        let r = SFSpeechAudioBufferRecognitionRequest()
        r.shouldReportPartialResults = true
        if rec?.supportsOnDeviceRecognition == true { r.requiresOnDeviceRecognition = true }
        req = r
        task = rec?.recognitionTask(with: r) { [weak self] res, _ in
            if let t = res?.bestTranscription.formattedString, t != self?.latest { self?.latest = t; self?.activity = Date() }
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            r.append(buf)
            // still talking (loud audio) keeps the recording open, but only once words have been recognised: room noise must not
            if let self, !self.latest.isEmpty, let d = buf.floatChannelData?[0] {
                let n = Int(buf.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += d[i] * d[i] }
                if n > 0, (sum / Float(n)).squareRoot() > 0.02 { self.activity = Date() }
            }
        }
        engine.prepare()
        do { try engine.start() } catch { return "Could not start the microphone: \(error.localizedDescription)" }
        startWatching()
        return nil
    }

    func cancel() {
        stopWatching()
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        task?.cancel(); req = nil; task = nil
    }

    func stop() async -> String {
        stopWatching()
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        req?.endAudio()
        try? await Task.sleep(nanoseconds: 800_000_000)
        task?.cancel(); req = nil; task = nil
        return latest
    }
}
