import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    @Published var input = ""
    @Published var reply = ""
    @Published var trace: [String] = []
    @Published var busy = false
    @Published var listening = false
    @Published var speaking = false
    @Published var focusTick = 0
    @Published var buildTick = 0
    @Published var pending: ConfirmRequest?
    @Published var needsAX = !AXIsProcessTrusted()
    private var answer: CheckedContinuation<Decision, Never>?

    var lamp: LampState { listening ? .listening : busy ? .thinking : speaking ? .speaking : .idle }

    init() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in let t = !AXIsProcessTrusted(); if self?.needsAX != t { self?.needsAX = t } }
        }
        speech.onChange = { [weak self] on in self?.speaking = on }
        agent.confirm = { [weak self] req in await self?.ask(req) ?? .deny }
    }

    private func ask(_ req: ConfirmRequest) async -> Decision {
        speech.stop()
        HUDController.shared.show()
        return await withCheckedContinuation { c in pending = req; answer = c }
    }

    func startListening() {
        speech.stop()
        if let problem = dictation.start() { reply = problem; return }
        listening = true
    }
    func finishListening() {
        guard listening else { return }
        listening = false
        Task { submit(await dictation.stop()) }
    }
    func cancelListening() {
        guard listening else { return }
        listening = false; dictation.cancel()
    }

    func toggleVoice() { listening ? finishListening() : startListening() }

    func decide(_ d: Decision) { pending = nil; answer?.resume(returning: d); answer = nil }

    let agent = Agent()
    let speech = Speech()
    let dictation = Dictation()

    func submit(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !q.isEmpty else { return }
        busy = true; trace = []; reply = ""
        Task {
            let r = await agent.run(q) { [weak self] line in Task { @MainActor in self?.trace.append(line) } }
            reply = r; busy = false
            speech.say(r)
        }
    }
}

struct HUDView: View {
    @ObservedObject var m: HUDModel
    @FocusState private var focused: Bool
    @AppStorage("permMode") private var modeRaw = "ask"
    private let shade = Color.black.opacity(0.35)

    var body: some View {
        VStack(spacing: 6) {
            LampView(state: m.lamp, build: m.buildTick) { m.toggleVoice() }
                .frame(width: 260, height: 260)
                .help("Tap the lamp to talk. Drag to turn it.")
            content
        }
        .padding(.horizontal, 56).padding(.vertical, 40)
        .frame(width: 560)
        .background(
            Rectangle().fill(.ultraThinMaterial)
                .mask(RoundedRectangle(cornerRadius: 120).padding(34).blur(radius: 34))
        )
        .onChange(of: m.focusTick) { _ in focused = true }
    }

    private var content: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(m.listening ? "Listening…" : "Ask Jinn…", text: $m.input)
                    .textFieldStyle(.plain).font(.system(size: 20, weight: .medium)).multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit { m.submit(m.input); m.input = "" }
                    .onExitCommand { m.speech.stop(); HUDController.shared.hide() }
                if m.busy { ProgressView().controlSize(.small) }
            }
            Capsule().fill(.primary.opacity(0.2)).frame(height: 1)
            if m.needsAX {
                Text("Jinn needs Accessibility to control apps.").font(.callout)
                Button("Allow Accessibility") { Permissions.askAccessibility() }.keyboardShortcut(.return, modifiers: .command)
                Text("Already listed? Select Jinn, press minus, then add it again after a rebuild.").font(.caption2).foregroundStyle(.secondary)
            }
            if let p = m.pending {
                Text("Allow? \(p.summary)").font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
                HStack {
                    Button("Allow once") { m.decide(.once) }.keyboardShortcut(.return, modifiers: .command)
                    if p.session { Button("This session") { m.decide(.session) } }
                    if p.persist { Button("Always") { m.decide(.always) } }
                    Button("Deny") { m.decide(.deny) }.keyboardShortcut(.escape, modifiers: [])
                }
            }
            if !m.reply.isEmpty {
                ScrollView { Text(m.reply).font(.system(size: 15)).multilineTextAlignment(.center).textSelection(.enabled).frame(maxWidth: .infinity) }
                    .frame(maxHeight: 150)
            }
            Button { modeRaw = modeRaw == "auto" ? "ask" : "auto" } label: {
                Text(modeRaw == "auto" ? "Auto: acts without asking, except shell and messages (click to switch)" : "Ask: confirms actions (click for Auto)").font(.caption2)
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            if !m.trace.isEmpty {
                DisclosureGroup("Trace (\(m.trace.count))") {
                    ScrollView {
                        Text(m.trace.joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 120)
                }.font(.caption)
            }
        }
        .shadow(color: shade, radius: 6)
    }
}
