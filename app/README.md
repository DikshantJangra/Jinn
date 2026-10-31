# Jinn (macOS app)

Native Swift always-on HUD agent. Gemma via Ollama, everything local. Python CLI in `../jinn` is the separate hackathon core.

```bash
ollama pull gemma4:e4b && ollama pull nomic-embed-text   # gemma4:e2b on 8GB
./build.sh && open build/Jinn.app
build/Jinn.app/Contents/MacOS/Jinn --selftest             # logic checks
build/Jinn.app/Contents/MacOS/Jinn --ask "tidy my downloads"  # headless, prints trace
```

- **The lamp** sits bottom-right (voice only). **Hover** it to zoom to the centre (type, read replies, approve); move away and it returns to the corner. Click the lamp or use **Option+Space** (tap or hold) to talk; Esc collapses and stops speech.
- **Undo**: say or type "undo" (or "undo 3" via the agent): moves files back, restores overwritten files and the clipboard, takes things out of the Trash, undoes typing, pulls back a Gmail send within seconds. Sent messages and shell commands are reported as not undoable.
- **Context**: the HUD shows how full the model's window is. Old screen reads are dropped first, then old steps become a one-line digest. Notes in the notes folder and files you connect ("remember this file") are retrieved only when relevant.
- **Permissions (once)**: Accessibility, Microphone, Speech Recognition, Automation (prompted per app).
- **Profile**: menubar > Edit me.md. Notes in `~/Library/Application Support/Jinn/notes/*.md` are retrieved by local embeddings.
- **Chrome form-fill**: `open -na 'Google Chrome' --args --remote-debugging-port=9222 --user-data-dir=$HOME/.jinn-chrome`
- **Env**: `JINN_MODEL` (default `gemma4:e4b`), `JINN_BIG_MODEL` (escalation for stalls / "think hard").
- **Approvals**: outward tools ask in the HUD. App-driving tools ask once per app (Allow once / Always). `run_shell` asks every time and hard-blocks dangerous patterns.
- **Debug**: every tool call is logged to `~/Library/Logs/Jinn/trace.jsonl`. `Jinn --tool app_state '{"app":"Finder"}'` runs one tool with no model and no approval prompt (dev only).
- Architecture and what was taken from each reference: [../docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).
- Ad-hoc signing changes per build, so macOS may ask to re-grant Accessibility after a rebuild.

Licensing: Agent! is PolyForm Noncommercial (the handoff doc said MIT). Two files contain its code and are noncommercial-only; mac-cua (Apache-2.0) ports are attributed. See [../NOTICE](../NOTICE) before any commercial use.

Deviations from the handoff doc: Apple Speech (on-device) instead of WhisperKit, native AX API instead of AXorcist, Carbon hotkey instead of KeyboardShortcuts, plain cosine instead of sqlite-vec. All swappable later.
