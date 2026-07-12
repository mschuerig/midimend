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
   before the implementation. Backfill status: script engine, config
   decoding, script-path resolution, name matching, and the device-selection
   rules (`EndpointSelection`) and the UMP word codec (`MIDI1UMP`) — both
   seams extracted from MIDIIO — are covered. Still untested: CLI argument
   handling (extract a Command parser from main.swift, or subprocess
   tests), Engine's hot-reload path (needs temp files and touches system
   MIDI), and MIDIIO's remaining CoreMIDI plumbing (would need device
   fakes; low value while it stays thin).
3. **Config template generation.** (done) `midimend --init script.js`
   evaluates the script's `PluginParameters` and prints a config skeleton
   to stdout with defaults filled in (menu defaults as their valueStrings
   entry, checkboxes as booleans; labels and momentary buttons omitted);
   script warnings go to stderr so the JSON can be redirected.
4. **Device robustness.** (done) `inputs` omitted defaults to all hardware
   inputs (excluding our own virtual ports — feedback-loop guard);
   hot-plugged devices connect via the existing setup-change notification.
   (Matching already uses the user-visible display name — the name shown
   in Audio MIDI Setup, including user renames.)
   - **Port exclusion:** (done) controllers often expose a second endpoint
     for DAW control (MCU/HUI + integration scripts), e.g. the MiniLab's
     "Minilab37 DAW" next to "Minilab37 MIDI" — they talk to the DAW
     directly and Midimend neither consumes nor forwards them. An
     `"ignore": ["DAW", …]` list in the `midi` section (same substring
     matching as `hardware`) wins over explicit input/output matches (a
     broad substring like "Minilab" would otherwise catch both ports) and
     over the default-all-inputs mode. Decided: no built-in or pre-defined
     ignore list — exclusion is fully explicit in the config, supported by
     `--list-devices`, which shows what is matched and ignored. The rules
     live in `EndpointSelection` (pure, unit-tested; shared by MIDIIO and
     `--list-devices`).
5. **Publish.** (done — v0.1.1 live 2026-07-12) GitHub repo `midimend`;
   license: No-Rights-Reserved; homebrew formula in
   `mschuerig/homebrew-tap` building from source, with a `service` block
   so `brew services start midimend` answers "how does the app run"
   (starts at login, restarts on crash). Release process per version:
   bump `midimendVersion`, tag, `packaging/release.sh vX.Y.Z`, rev
   url+sha256 in `packaging/midimend.rb`, copy to `~/Projekte/homebrew-tap`
   (Michael's clone — never the brew-managed tap dir), push.
   - **Config home (decided):** `~/Music/Midimend/config.json` — visible
     in Finder and musician-idiomatic (like `~/Music/Audio Music Apps`);
     `~/Library/Application Support` rejected because it is meant for
     app-managed files, not hand-edited documents. Bare `midimend` (and
     thus the brew service) runs this config and prints a
     create-it-like-this message when it is missing.
   - **Single-file binary:** Bootstrap.js is compiled into the executable
     (SwiftPM `.embedInCode`), so there is no resource bundle to ship for
     *any* install method — one Mach-O to install, sign, and notarize.
     Caveat: the combined `--arch arm64 --arch x86_64` build routes
     through the Xcode build system, which doesn't support `.embedInCode`;
     universal binaries are built per-arch with `--triple` and merged
     with `lipo` (done this way in the release workflow).
   - **Formula draft:** `packaging/midimend.rb` — installs the binary, man
     page (`packaging/midimend.1`), and zsh/bash completions
     (`packaging/completions/`). `keep_alive crashed: true` restarts after
     crashes but not after deliberate exits (missing config), avoiding a
     respawn loop. CI: `.github/workflows/ci.yml`.
   - **Binary release:** `packaging/release.sh`, run locally against a
     pushed tag — builds the universal binary, checks it against
     `midimendVersion` (in main.swift — bump per release; `--version`
     flag), signs, notarizes, and publishes a GitHub release with the
     zip. Decided: signing stays local — CI signing was drafted and
     discarded because anything that can run a workflow in the repo can
     read its secrets, and exporting the Developer ID key to GitHub
     widens its exposure from "this Mac" to "the GitHub account". CI
     (`ci.yml`) builds and tests only and holds no secrets.
   - **Status:** v0.1.1 (2026-07-12) is the released state — signed
     (Developer ID G2 cert, valid to 2031), notarized, brew-installed
     and running as a service on Michael's machine with the MiniLab
     connected and the service log confirmed working (v0.1.0's stdout
     buffering bug fixed). MainStage picks up "Midimend Out"; the
     saved-connection re-bind across a midimend restart hasn't been
     explicitly exercised yet.
   - **Signing:** implemented in `packaging/release.sh` (waiting on the
     certificate/API-key setup, see above) — not strictly required for a
     from-source formula (curl-downloaded files carry no quarantine
     attribute, so Gatekeeper never evaluates them), but a matter of
     courtesy towards users. Sign with a "Developer ID Application"
     certificate (`codesign --options runtime --timestamp` + entitlements
     file), then notarize (`xcrun notarytool submit --wait`). Hardened
     runtime blocks JavaScriptCore's JIT; `packaging/midimend.entitlements`
     carries `com.apple.security.cs.allow-jit` (without it JSC silently
     falls back to the interpreter — harmless at MIDI rates, but the
     entitlement is the clean fix). A bare executable/zip cannot be
     stapled; Gatekeeper fetches the notarization ticket online, or ship
     a `.pkg`/`.dmg` if offline install matters.

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
  says the dispatch hop matters. Measurement exists: `--measure` runs
  normally and prints added-latency percentiles (driver receipt → script
  entry / → processing done) every 10 s, from the driver-receipt
  timestamps CoreMIDI puts on incoming packets.
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
