# How Jinn is put together

Jinn is really two programs that share a name and a goal: run Gemma on your own machine and keep everything local.

- **`jinn/`** is a small Python package (CLI, planner, workspace tools). It was the hackathon core and has no third-party dependencies.
- **`app/`** is the Swift macOS app: a floating HUD you summon with Option+Space that listens, thinks with a local model, and drives your Mac with tools.

They don't call each other. The only thing they share is Ollama and the `JINN_MODEL` environment variable. This document is mostly about the app, because that's where the moving parts are. The Python side gets a short section at the end.

Parts of the macOS app follow designs from two open-source projects, mac-cua and Agent!. Which files came from where is listed in [../NOTICE](../NOTICE), and it matters for licensing, so read it before using Jinn commercially.

## What happens when you ask for something

1. You press Option+Space. A tap toggles the HUD. If you hold it, Jinn starts listening and runs your request when you let go.
2. `Voice/Dictation` turns speech into text using Apple's on-device recognizer. Nothing is sent anywhere.
3. `Agent.run` in `Brain/AgentLoop.swift` builds the prompt from the system prompt, your `me.md` profile, any matching notes, and the last 20 messages of history.
4. The model is called through Ollama's `/api/chat`, with the tool schemas attached.
5. If the model asks for tools, each call goes through approval, then runs, then its result is fed back. This repeats until the model answers in plain text or the round limit (12 by default) is hit.
6. The answer is shown in the HUD and read aloud with `AVSpeechSynthesizer`.

The same loop backs `Jinn --ask "..."`, which is the quickest way to debug without the UI. `Jinn --tool app_state '{"app":"Finder"}'` runs a single tool with no model and no approval prompt.

## The layers

Each folder under `app/Sources/Jinn` is a layer, and imports should only point downward.

```
Overlay/  Voice/   the shell: HUD panel, lamp animation, hotkey, speech in and out
Brain/             the agent loop, model clients, history compaction
Memory/            me.md, notes, embedding search
Tools/             the tool registry: name, schema, risk level, run closure
Hands/             everything that touches macOS: accessibility, input, screen, Chrome, shell
Core/              errors, safety rules, approvals, permissions, retry, tracing
```

It's a rule of thumb more than a law, and two spots bend it:

- `Core/Permissions.swift` takes a `Tool` so it can tell whether a tool needs Accessibility.
- `Core/Approvals.swift` stores its file in the folder `Memory/ContextStore` defines.

Neither is hard to untangle, but nobody has needed to yet. The part that matters is that `Hands` never knows about the model, so you can run any tool without one (that's what `--tool` does).

### Hands

This is the part that actually operates the Mac, and where most of the mac-cua ideas live.

| File | Job |
| --- | --- |
| `Accessibility.swift` | Thin wrapper over the AX API: attributes, error descriptions, a global 1.5 s messaging timeout |
| `Snapshot.swift` | Walks an app's accessibility tree into numbered `Node`s and renders it for the model within a token budget. `Snapshot.diff` reports what changed after an action |
| `Prune.swift` | Shrinks that tree: merges labels into their controls, collapses wrappers, joins adjacent text |
| `Click.swift` | The click strategy, in order: select rows, press the element (or a pressable ancestor), then fall back to a synthesized click |
| `Input.swift`, `Keys.swift` | Mouse and keyboard events posted to one process, never the global event stream. Typing goes key by key and uses unicode only when there's no key code. Combos like `cmd+shift+a` are parsed here |
| `Screen.swift` | For apps whose accessibility tree is empty: `screencapture` plus Vision OCR, then click or wait by on-screen text |
| `ChromeBridge.swift` | Runs JavaScript in Chrome tabs, over the remote debugging port on 9222 if it's open, or AppleScript if it isn't |
| `Apps.swift` | Finds, launches (optionally with `open -g`) and resolves apps, and refuses blocked ones |
| `Interrupt.swift` | Notices when you touch the mouse or keyboard mid-task and backs off that app |
| `Shell.swift` | Runs processes with a timeout, plus the AppleScript helper |

Element indices belong to one snapshot. If the tree changes underneath, using an old index returns a "stale" error that tells the model to call `app_state` again. Password fields are recognized (`Node.secure`) and never read or filled, in native apps or on web pages.

### Tools

Everything the model can do is a `Tool`: a name, a description, parameters, a `Risk`, and a closure. The `schema` property turns that into the JSON Ollama expects. `allTools` in `Tool.swift` is the single list the agent loop and the model both see.

| Group | Tools |
| --- | --- |
| Accessibility | `list_apps`, `screen_read`, `app_state`, `click`, `set_value`, `type_text`, `press_key`, `scroll`, `perform_action` |
| Screen (no AX tree) | `screen_ocr`, `click_text`, `click_at`, `move_cursor`, `wait_for_text` |
| Files and system | `find_files`, `open_file`, `reveal_in_finder`, `list_dir`, `read_file`, `write_file`, `make_folder`, `copy_file`, `move_file`, `trash_file`, `organize_downloads`, `clipboard_get`, `clipboard_set`, `open_settings` |
| Apps | `open_app`, `quit_app`, `close_window`, `activate_app`, `hide_app`, `read_unread_mail`, `draft_mail`, `send_message` |
| Chat apps | `find_chat`, `send_chat` |
| Web | `web_search`, `web_fetch`, `ping`, `open_url` |
| Chrome | `chrome_tabs`, `chrome_page`, `chrome_read_form`, `chrome_fill_form`, `chrome_click` |
| Shell | `run_shell` |
| Memory | `remember` |

`Tools/Guidance.swift` holds short per-app tips (how to message someone in WhatsApp, which Mail tools to prefer) that are handed to the model.

To add a capability: put the macOS plumbing in `Hands/`, wrap it in a `Tool` in `Tools/`, and add the group to `allTools`. To add a model backend: write another `Brain` conformer.

### Brain

- `Brain` is a two-method protocol: `chat(messages, tools)` and a `model` name.
- `OllamaClient` is the default. Every request sets `num_ctx` (16384 unless `JINN_CTX` says otherwise) and `keep_alive: 30m`, and the app warms the model at launch so the first answer isn't slow.
- `TextToolCalls` rescues small models that write a call as plain text (`list_dir {"path":"~"}`) instead of using real tool calls.
- `Compaction` keeps history inside a character budget by clipping old tool output first, then dropping the oldest turns. The system prompt always survives.

The loop also guards against a few things small models do. It nudges the model if its reply was cut off, or if it claims "I opened it" without calling anything. It stops after the same call three times in a row, or when a call that already failed is repeated. When `JINN_BIG_MODEL` is set, those stalls (and the phrase "think hard") switch the conversation to the bigger model instead of giving up.

### Memory

Jinn's memory is plain files under `~/Library/Application Support/Jinn/` (set `JINN_HOME` to use another folder):

- `me.md` is the profile: `Key: value` lines (Name, Email, Phone...), your own free-form `##` sections, and a `## Learned` list of bullets Jinn adds. It goes into every prompt in full, with a "Not set yet" line so the model asks once for what is missing.
- `notes/**/*.md|txt` is a library you can drop anything into. It is searched, never pasted whole.
- `index.json` caches embeddings by text hash, so only new or edited text is ever embedded again.

`Memory/` is split by what can be tested without a model: `Profile.swift` (parse and edit me.md), `Retrieval.swift` (tokenizer, BM25, rank fusion, chunking, secret detection) and `ContextStore.swift` (files, embedding cache, the tools). `--selftest` covers the first two.

**Retrieval.** Each request runs a hybrid search: BM25 for exact words (names, IDs) and `nomic-embed-text` cosine for paraphrases ("food allergies" finds "Allergic to peanuts"), merged with Reciprocal Rank Fusion. Embeddings use nomic's `search_document:` / `search_query:` prefixes, which Ollama does not add. A hit must pass a relevance gate (cosine 0.52 or BM25 1.0), so an unrelated request gets no notes. If the embedding model is missing or Ollama is down, search quietly falls back to BM25. `Jinn --recall "query"` prints the hits and their scores.

**Where memory is used.**

1. Every run: the profile plus relevant notes go into the system prompt, labelled as data, not instructions.
2. Forms: `chrome_open` and `chrome_read_form` append "Profile hints" (`"Email address" -> "r@x.com"`), matched by field synonyms (mobile = phone, employer = company). "Company name" is never answered with your name.
3. Mid-task: the `recall` tool searches everything when the prompt does not have the answer.
4. Writing: `update_profile` sets a field (asks first if it would overwrite a value); `remember` adds a learned fact. Both skip duplicates and refuse anything that looks like a password, code, key or card number.
5. After a turn: if your own message states something about you ("I work at Acme", "call me Rit"), a short extra model call files it under `## Learned` and the HUD log shows `remembered: ...`. Only your words are used, never tool output or page text, so a web page cannot plant a "fact".

Similarity is plain cosine over an in-memory array, which is plenty for personal notes and avoids a database dependency.

### Overlay and Voice

The HUD is a borderless, non-activating `NSPanel` hosting SwiftUI, so it floats over every Space without stealing focus from the app you're working in. The lamp is a WebGL scene (`Resources/lamp/lamp.html`, three.js) inside a `WKWebView`. The app tells it whether Jinn is idle, listening, thinking or speaking, and it tells the app when you tap it.

## Staying safe

Giving a small local model control of your computer needs guardrails. There are four, and they stack.

**Risk levels.** Each tool declares one:

| Risk | What happens |
| --- | --- |
| `.safe` | Runs straight away |
| `.confirm` | Asks in the HUD every single time |
| `.app(argKey)` | Asks once per app. "Allow once" lasts the session; "Always" is saved to `approvals.json` |

If nothing is attached to answer the prompt, the answer is no. "Auto mode" in the menu bar skips the per-app prompts, but tools marked `alwaysAsk` (shell, sending messages) still ask.

**App blocklist.** `Core/Safety.swift` refuses to drive Terminal, iTerm, Keychain Access, System Settings, password managers and Jinn itself.

**Shell filtering.** `run_shell` is always confirmed, and the command is checked first. `ShellSafetyService` catches catastrophic commands. A second list in `Safety.swift` covers things like `sudo`, piping curl into a shell, disk formatting, credential stores and reverse shells.

**Web vetting.** `Web.vet` rejects anything that isn't plain http(s) to a public host: localhost, private ranges, link-local and cloud metadata addresses, and the numeric or hex tricks that disguise them.

Every tool call is appended to `~/Library/Logs/Jinn/trace.jsonl` with its arguments, a trimmed result and how long it took. When something goes wrong, look there first.

## Things we looked at and left out

- **A root helper daemon** for privileged operations. It adds attack surface and Jinn has no use for it.
- **Cloud providers and remote control.** Jinn is local-first on purpose.
- **An MCP server layer.** The tools run in-process. `Tool` already has the right shape (name, JSON schema, run), so exposing them over MCP later would be a thin wrapper.
- **ScreenCaptureKit, private window APIs and a virtual cursor.** OCR via `screencapture` and Vision covers what we need today. These become worth it when a vision model joins the loop.

## The Python package

```
jinn/
  cli.py       jinn info | plan "..." | audit --dir .
  agent.py     JinnAgent: asks the model for a plan and parses the JSON
  engine.py    GemmaLocalEngine: talks to Ollama over HTTP, falls back to a canned plan
  prompts.py   system prompt and planning prompt
  tools.py     LocalToolKit: workspace scan, Python file analysis, system info
```

`GemmaLocalEngine` reads `JINN_MODEL` (default `gemma4:e4b`). If Ollama is unreachable or the call fails, it quietly returns a canned three-step plan so the tests and demos still run. When you're checking real behaviour, look at `engine_mode` in the output: `local_hardware_gemma` means the model actually answered, `local_fallback` means it didn't.

The planner expects JSON back, but Ollama doesn't force it for Gemma 4, so `plan_task` pulls out whatever sits between the first `{` and the last `}` and falls back to returning the raw text if that still isn't valid JSON.

## Running the checks

```bash
python -m pytest                              # Python tests
cd app && swift build -c release
.build/release/Jinn --selftest                # Swift logic checks, no model or permissions needed
```

CI runs both on every push to `main`.
