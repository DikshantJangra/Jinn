import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    @Published var input = ""
    @Published var reply = ""
    @Published var trace: [String] = []
    @Published var busy = false
    @Published var listening = false
    @Published var focusTick = 0
    @Published var pending: ConfirmRequest?
    private var answer: CheckedContinuation<Decision, Never>?

    init() {
        agent.confirm = { [weak self] req in await self?.ask(req) ?? .deny }
    }

    private func ask(_ req: ConfirmRequest) async -> Decision {
        speech.stop()
        HUDController.shared.show()
        return await withCheckedContinuation { c in pending = req; answer = c }
    }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: m.listening ? "waveform" : "wand.and.stars").foregroundStyle(.secondary)
                TextField(m.listening ? "Listening…" : "Ask Jinn…", text: $m.input)
                    .textFieldStyle(.plain).font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { m.submit(m.input); m.input = "" }
                    .onExitCommand { m.speech.stop(); HUDController.shared.hide() }
                if m.busy { ProgressView().controlSize(.small) }
            }
            if let p = m.pending {
                Text("Allow? \(p.summary)").font(.callout).textSelection(.enabled)
                HStack {
                    Button(p.scope == nil ? "Allow" : "Allow once") { m.decide(.once) }.keyboardShortcut(.return, modifiers: .command)
                    if let s = p.scope { Button("Always allow \(s)") { m.decide(.always) } }
                    Button("Deny") { m.decide(.deny) }.keyboardShortcut(.escape, modifiers: [])
                }
            }
            if !m.reply.isEmpty {
                ScrollView { Text(m.reply).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140)
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
        .padding(14)
        .frame(width: 440)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: m.focusTick) { _ in focused = true }
    }
}
