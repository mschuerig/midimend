# Planning

Living document: near-term plan, roadmap, and the design notes behind them.
Deliberately postponed features live in [IDEAS.md](IDEAS.md) with their own
design notes.

**Guiding principle:** easy to use for non-technical users (most musicians) —
as few surprises as possible, and problems must be easy to diagnose.

## Now (v0.x) — toward a first release

1. **Diagnosis basics.** (done) `--list-devices [config.json]` prints the
   endpoints present, marks the ones the config's `hardware` entries match,
   and flags entries that match nothing; at startup, a configured device
   that isn't found produces a warning listing the devices that *are*
   present (it still connects automatically when it appears).
2. **Testing.** Test-first from here on: new behavior gets a failing test
   before the implementation. Backfill coverage for existing code — config
   loading and script-path resolution, CLI argument handling, and MIDIIO's
   pattern-matching/missing-device logic (needs a seam so it can run
   without CoreMIDI devices; the script engine is already covered).
3. **Config template generation.** `midimend --init script.js` evaluates the
   script's `PluginParameters` and prints a config skeleton with defaults
   filled in.
4. **Device robustness.** Default to all inputs when `inputs` is omitted
   (excluding our own virtual ports — feedback-loop guard); connect
   hot-plugged devices via the existing setup-change notification.
   (Matching already uses the user-visible display name — the name shown
   in Audio MIDI Setup, including user renames.)
   - **Port exclusion:** controllers often expose a second endpoint for DAW
     control (MCU/HUI + integration scripts), e.g. the MiniLab's
     "MiniLab37 DAW" next to "MiniLab37 MIDI". These must be ignorable —
     they talk to the DAW directly and Midimend should neither consume nor
     forward them. Design: a top-level `"ignore": ["DAW", …]` list (same
     substring matching as inputs), applied both to explicit input matches
     (a broad substring like "MiniLab" would otherwise catch both ports)
     and to the default-all-inputs mode. Decided: no built-in or
     pre-defined ignore list — exclusion is fully explicit in the config,
     supported by a `--list-devices` that shows what is connected, matched,
     and ignored.
5. **Publish.** GitHub repo `midimend` (done); license: No-Rights-Reserved
   (done); homebrew formula in `mschuerig/homebrew-tap` building from
   source, with a `service` block so `brew services start midimend`
   answers "how does the app run" (starts at login, restarts on crash).
   - **Signing:** skipped for now, but to be set up as soon as midimend is
     distributed via homebrew — not strictly required for a from-source
     formula (curl-downloaded files carry no quarantine attribute, so
     Gatekeeper never evaluates them), but a matter of courtesy towards
     users. Recipe: sign with a "Developer ID Application" certificate
     (`codesign --options runtime --timestamp` + entitlements file), then
     notarize (`xcrun notarytool submit --wait`). Hardened runtime blocks
     JavaScriptCore's JIT; add the `com.apple.security.cs.allow-jit`
     entitlement (without it JSC silently falls back to the interpreter —
     harmless at MIDI rates, but the entitlement is the clean fix). A bare
     executable/zip cannot be stapled; Gatekeeper fetches the notarization
     ticket online, or ship a `.pkg`/`.dmg` if offline install matters.
     Natural home: a GitHub Actions release workflow, signing between
     build and upload.

## v1 — timing

Internal transport (tempo/meter/auto-play from config), `TimingInfo`,
`beatPos`, `ProcessMIDI` tick, `Reset`, beat-domain scheduling for
`sendAtBeat`/`sendAfterBeats`.

Design notes:

- **Scheduler:** priority queue keyed on host time (`mach_absolute_time`);
  beat→time conversion at the tempo source; re-map queued beat events on
  tempo change. Don't rely on CoreMIDI future timestamps — they are only
  honored for hardware destinations; virtual-source listeners just receive
  the raw timestamp.
- **`ProcessMIDI` cadence:** high-priority timer tick with configurable
  interval (default ≈ 2.9 ms, i.e. 128 samples at 44.1 kHz);
  `blockStartBeat`/`blockEndBeat` derived from the internal transport.
- **Config additions:** `transport` section
  (`{ "tempo": 120, "meter": [4, 4], "autoPlay": true, "sync": "internal" }`),
  optional `processBlock.intervalMs`.

## v1.x — sync

MIDI Clock slave (Start/Stop/Continue + Song Position Pointer), maybe
Ableton Link.

- Clock receive needs jitter smoothing/PLL — ±1 ms input jitter over USB is
  typical; stability-vs-responsiveness tradeoff. This is the hardest single
  component; internal transport stays the default. SwiftMIDI (orchetect)
  ships a MIDI Clock/MTC receiver that could cut this work substantially.
- Ableton Link is GPLv2+ or paid proprietary — fine only if the licensing
  fits; defer until it matters.

## Compatibility

- Long-tail behaviors to verify against the original plug-in: `Trace`
  thinning, `beatPos` semantics while stopped, mixed-meter beat scaling,
  menu-parameter index mapping, constructor defaults (`new NoteOn()` without
  arguments).
- Goal: a side-by-side test suite running published example scripts against
  both engines, treating observed plug-in behavior as the spec.
- Robustness beyond the original: per-callback exception containment (done);
  consider a watchdog on callback duration.

## Architecture notes (for future work)

- **Threading (as implemented):** all JS access is confined to one serial
  GCD queue (`midimend.js`, userInteractive QoS) — incoming events hop onto
  it from the CoreMIDI receive thread; idle timer, file watchers, reloads,
  and `sendAfterMilliseconds` target the same queue. System real-time
  messages bypass the queue (passed through on the receive thread;
  thread-safe, may reorder slightly vs. processed events).
  **Revisit at v1:** the ~3 ms `ProcessMIDI` tick and beat scheduler are
  jitter-sensitive; consider a dedicated JS thread owning a run loop —
  JSC registers GC-housekeeping timers on the VM-creating thread's run
  loop, which never fires on a GCD worker, so GC currently runs
  synchronously on allocation thresholds (sub-ms at our heap sizes,
  harmless today) — and only add a lock-free receive ring if measurement
  says the dispatch hop matters.
- **Port persistence (implemented):** virtual ports get a stable
  `kMIDIPropertyUniqueID` (name hash) so other apps' saved connections
  re-bind across restarts; on collision CoreMIDI keeps its random ID.
  Not yet verified end-to-end against a DAW's saved connections.
- **Receiver-side suppression:** CoreMIDI has no exclusive capture; DAWs must
  ignore raw hardware via input-port selection (documented in the README).
- **iOS (distant):** keep the core platform-neutral (engine + scheduler +
  transport, no I/O assumptions). Virtual endpoints on iOS require
  `UIBackgroundModes: audio` and an app shell; JSC runs interpreter-only
  there — irrelevant at MIDI rates.
