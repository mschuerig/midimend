# Ideas — postponed until there's an actual need

Parked deliberately (2026-07). Revisit when a real use case pulls them in.
Design notes preserved here so we don't have to re-derive them.

## Chained scripts

Run several scripts as a pipeline: script 1's output feeds script 2, and so
on; only the last stage emits to the MIDI outputs.

- **Engine model**: one `JSContext` per script, all sharing a single
  `JSVirtualMachine`. Near-zero overhead (one VM/heap), but isolated globals —
  mandatory, since every Scripter script defines the same names
  (`HandleMIDI`, `PluginParameters`, …).
- **Routing semantics**: `event.send()` in stage N injects into stage N+1,
  not the MIDI output. Scheduled events (`sendAfterMilliseconds`) re-enter
  the chain at the *next* stage when they fire — matching chained Scripter
  plug-ins in Logic.
- **Config**: `script` becomes an array of `{ script, parameters }` entries.
  Breaking schema change — consider adopting the array form (with a single
  entry supported) *before* the config format is published, even if chaining
  itself ships later.

## Switchable presets (MIDI Program Change)

Open question first: what does a "preset" switch?

- (a) parameter value sets for the same script(s) — cheap, analogous to
  Scripter settings; most likely what's needed for MainStage use.
- (b) whole script chains — heavier, but the hot-reload machinery exists.
- (c) whole configs including MIDI routing — ruled out; port churn
  mid-performance invites trouble.

Also to decide: which port/channel listens for the PC, and whether that PC
still passes through to the DAW.

## Menu bar app shell

A finicky-style shell (<https://github.com/johnste/finicky>): no window,
status icon, enable/disable toggle, reload, error notifications instead of
stdout traces; config stays a watched file.

- Requires an app bundle → Xcode project (SwiftPM can't build .app bundles),
  signing/notarization, homebrew *cask* instead of formula.
- Interim answer for "how does the app run": `brew services`
  (launchd via the homebrew formula — starts at login, restarts on crash).
- Build only when pulled by a concrete pain point.
