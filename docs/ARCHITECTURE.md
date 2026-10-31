# Jinn architecture

Studied and partly ported: mac-cua (Apache-2.0, 3 layers: MCP / session / platform backend) and Agent!
(PolyForm Noncommercial). Ports and the two files containing Agent! code are listed in ../NOTICE.

## Layers (dependency points down only)

```
Overlay/ Voice/  app shell: HUD, hotkey, speech            -> Brain, Core
Brain/           agent loop, providers, compaction          -> Tools, Core
Tools/           tool registry: name, schema, risk, run     -> Hands, Core
Hands/           macOS: snapshots, AX, input, Chrome, shell -> Core
Core/            errors, safety, approvals, trace, retry    -> Foundation only
```

Rule: Hands never imports Brain; Core imports nothing of ours. Adding a capability = one file in Hands + one
`[Tool]` list in Tools + registration in `allTools`. Adding a model backend = one `Brain` conformer.

## What we took from each reference (as design, not code)

| Idea | Source | Jinn |
| --- | --- | --- |
| Snapshot-local element indices, stale detection | mac-cua | `Hands/Snapshot.swift`, `Node.index`, `JinnError.stale` |
| Prune the UI tree to a token budget | mac-cua | `Snapshot.render(budget:)` |
| Reliability ladder: AX action > set value > click element > coordinates | mac-cua | `click`: AXPress, then synthesized click |
| Input posted to a pid, never the global stream; isolated event source | mac-cua | `Hands/Input.swift` |
| xdotool-style key combos | mac-cua | `Hands/Keys.swift` |
| Return fresh state after each action (verify by snapshot diff) | mac-cua | `Snapshot.diff`, tool results |
| Per-app interruption backoff | mac-cua | `Hands/Interrupt.swift` |
| App blocklist, per-app approval (session / persistent) | mac-cua | `Core/Safety.swift`, `Core/Approvals.swift` |
| Retry with backoff, typed errors, tracing | mac-cua | `Core/Retry.swift`, `Core/Errors.swift`, `Core/Trace.swift` |
| Per-app operational hints | mac-cua | `Tools/Guidance.swift` |
| Click ladder: AXSelected for rows, AXPress (or pressable ancestor), pointer first inside web content, window-id hints, element's own pid | mac-cua | `Hands/Click.swift`, `Input.click` |
| Per-char key-code typing, unicode only as fallback; modifiers as flags, never flagsChanged | mac-cua | `Input.type`, `Keys.forChar` |
| AX error code table; global AX messaging timeout | mac-cua | `AX.describe`, `AX.configure` |
| Background launch (`open -g`) | mac-cua | `open_app background:true` |
| Password fields never read or filled (AX and web) | Agent! (restricted AXSecureTextField) | `Node.secure`, Chrome tools |
| `num_ctx` + `keep_alive` on every Ollama call, warm-up at launch | Agent! | `OllamaClient.body`, `warm()` |
| Continue on truncated output; challenge "I clicked..." with no tool call | Agent! LoopControl | `loopCorrection` |
| Shell command safety classifier | Agent! | `Safety.shell` + `run_shell` (always confirmed) |
| History compression to fit small context | Agent! | `Brain/Compaction.swift` |
| Provider abstraction (local backends) | Agent! | `Brain` protocol: Ollama, OpenAI-compatible (LM Studio, llama.cpp, vLLM) |
| Stall detection (failed repeat, 3x identical call), escalation that continues the same conversation | Agent! | `Brain/AgentLoop.swift` |

## Deliberately not taken

- Root XPC daemon / privilege escalation (Agent!): attack surface, no Jinn use case.
- 20+ cloud providers, Apple Intelligence mediator, AgentScripts, Messages remote control: out of scope; local-first.
- MCP server layer (mac-cua): Jinn calls its Hands in-process. `Tool` already has the shape (name, JSON schema, run) if we want to expose an MCP server later.
- ScreenCaptureKit screenshots / vision, SkyLight SPIs, virtual cursor: add when a vision model is in the loop.

## Risk model

`Tool.risk`: `.safe` runs; `.confirm` asks the HUD every call; `.app(argKey)` asks once per app (Allow once =
this session, Always = persisted in Application Support/Jinn/approvals.json). No confirm handler = deny.
