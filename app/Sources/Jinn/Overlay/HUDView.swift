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
    /// false = just the lamp in the corner (voice only); true = zoomed to the centre with typing and replies.
    @Published var expanded = false
    /// Tokens in the last prompt and the model's window: the context meter.
    @Published var ctx: (used: Int, limit: Int)?
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
        dictation.onAutoStop = { [weak self] in Task { @MainActor in self?.finishListening() } }
        agent.onContext = { [weak self] u, l in Task { @MainActor in self?.ctx = (u, l) } }
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
        // "undo" is answered straight from the journal: instant, and it cannot be misheard into something else
        if ["undo", "undo that", "undo it", "revert", "revert that", "take that back", "go back"].contains(q.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            busy = true; trace = []
            Task { let r = await Undo.shared.undo(); reply = r; busy = false; speech.say(r) }
            return
        }
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
                .frame(width: m.expanded ? 260 : 130, height: m.expanded ? 260 : 130)
                .help("Click the lamp to talk. Drag to turn it.")
                .overlay(alignment: .topTrailing) {
                    Button { HUDController.shared.toggle() } label: {
                        Image(systemName: m.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .semibold)).padding(7)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain).disabled(m.pending != nil)
                    .help(m.expanded ? "Back to the corner (Esc)" : "Open Jinn to type")
                }
            if m.expanded { content }
        }
        .padding(.horizontal, m.expanded ? 56 : 10).padding(.vertical, m.expanded ? 40 : 10)
        .frame(width: m.expanded ? 560 : 150)
        .background {
            if m.expanded {
                Rectangle().fill(.ultraThinMaterial)
                    .mask(RoundedRectangle(cornerRadius: 120).padding(34).blur(radius: 34))
            }
        }
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
            if let c = m.ctx, c.limit > 0 {
                let pct = min(100, c.used * 100 / c.limit)
                Text("Context \(pct)%  \(c.used)/\(c.limit) tokens\(pct >= 80 ? "  (older steps are being compacted)" : "")").font(.caption2)
                    .foregroundStyle(pct >= 80 ? .orange : .secondary)
            }
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
