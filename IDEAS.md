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

Switch presets from a controller's Program Change. Design settled in
discussion (2026-07-12); still no use case — do not build until one pulls it.

**A preset is just a reused `Config`** (script path + parameters). No new
file format. That covers both (a) same script, different parameter sets —
the cheap, MainStage-flavored case — and (b) a different script entirely,
since `Config` carries the script path. Ruled out: (c) presets that change
MIDI routing — port churn mid-performance invites trouble, and port changes
already require a restart.

**File layout**: one file (or symlink) per PC number under `~/Music/Midimend`.

- `NNN_name.json`, **1-based** (`001`–`128`) to match what controllers
  *display*. `000_default.json` is the initial preset and the fallback when
  no dedicated file exists. Because numbering is 1-based, no real program can
  map to `000` — the default slot is genuinely out-of-band and can't collide.
- The wire is still 0-based, so the engine maps **incoming byte _n_ → file
  `(n+1)`** (wire 0 → `001`, wire 127 → `128`). That `+1` is the whole
  off-by-one, in one place — comment it, or a future reader will "fix" it.
- Aliasing is a filesystem op: `050_house.json → 000_default.json` makes
  program 50 the default too. No config surface needed.

**Switch mechanism = `Engine.performReload()` keyed by program number**
instead of a file-write event. That path already loads a `Config`, builds a
fresh `ScriptEngine` on `jsQueue`, and swaps the pointer. Reuse it.

- **Stateless rebuild per switch — no engine cache.** Construction re-fires
  `ParameterChanged` for every parameter, so the script re-inits from current
  values, exactly like loading a plug-in setting — the musically-correct
  behavior. Caching warm contexts reintroduces stale state on switch-back and
  breaks the idle-GC assumption (`JSGarbageCollect` touches only the active
  context). Reach for a bounded LRU cache *only* if measurement shows a real
  script's build blocks audibly during in-performance switching.
- **Latency is likely a phantom.** The switch cost is `ScriptEngine`
  construction (new `JSContext` + bootstrap + user-script eval + JIT warmup —
  the "one-off 1.2ms" already in the threading note), not per-event latency.
  It runs on `jsQueue`, so it briefly delays queued events, but PC switches
  happen at musical boundaries, not mid-phrase, so a few ms one-time is
  inaudible. Confirm with one measurement (time `makeScriptEngine()` for a
  heavy example script) before optimizing anything.
- **Pre-load configs at startup for validation, not speed.** Parsing ~128
  small files is trivial and buys nothing latency-wise (page cache is just as
  fast on demand); the point is fail-fast — warn "preset 004 failed to load"
  at startup rather than a silent no-op when the user dials it up mid-set.
- File watching widens from the two active files to the preset directory; a
  switch re-points watchers, as `performReload()` already re-installs them.

**Listening**: a global set of channels listens for PC (global, alongside the
existing config). 128 slots is plenty — leave Bank Select (CC0/CC32) out.

**Swallow vs. pass-through: configurable, default swallow.** One global
boolean (name it for the true=default reading, e.g. `swallowProgramChange:
true` — avoid a double-negative default). Scope: swallow applies only to PCs
on the *matched listen channels*; PCs on any other channel always pass through
as normal musical data. Swallow regardless of whether the switch found a
preset — the behavior is about the channel's control-plane role, not about
whether the switch succeeded (otherwise the buttons leak "sometimes").

## Feedback-path script

Run a script on the parameter-feedback path (DAW → paired virtual
destination → controllers), mirroring the forward path. Needed only when a
forward script *renumbers* the controls a DAW echoes back — then feedback
must be reverse-mapped before it reaches the controller. Plain LED-ring
feedback (X-Touch Mini) needs pass-through only, which is what the feedback
feature ships with.

- **Engine model**: a second, independent `ScriptEngine` instance on the
  feedback path (own `JSContext`; can share the `JSVirtualMachine`). The
  Scripter API is directionless, so the same API works — but state is *not*
  shared with the forward script; a script that needs to correlate both
  directions has no home yet (and no use case).
- **Config**: `"feedback"` grows from `"all"`/list into an object,
  e.g. `{ "script": "reverse.js", "outputs": "all" }` — decide the exact
  shape when a use case exists.

## Menu bar app shell

A finicky-style shell (<https://github.com/johnste/finicky>): no window,
status icon, enable/disable toggle, reload, error notifications instead of
stdout traces; config stays a watched file.

- Requires an app bundle → Xcode project (SwiftPM can't build .app bundles),
  signing/notarization, homebrew *cask* instead of formula.
- Interim answer for "how does the app run": `brew services`
  (launchd via the homebrew formula — starts at login, restarts on crash).
- Build only when pulled by a concrete pain point.
