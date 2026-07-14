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
   decoding, script-path resolution, name matching, the device-selection
   rules (`EndpointSelection`), the UMP word codec (`MIDI1UMP`), CLI
   argument handling (`CLICommand`, extracted from main.swift), the
   plug/unplug log lines (`EndpointChanges`) and connect/prune decisions
   (`SourceSync`) — all pure seams — plus Engine's hot-reload path
   (temp files, real but uniquely-named virtual ports) are covered.
   - **End-to-end layer (the lesson of the hot-plug bug, 2026-07-13):**
     `EndToEndTests` spawns the real binary and simulates hot-plug by
     creating a virtual source (which fires `.msgSetupChanged`
     system-wide), asserting the appear/connect/process/disappear chain.
     This layer exists because main.swift's `dispatchMain()` ran no
     CFRunLoop, so setup-change notifications never fired — a bug that
     shipped despite a green unit suite, since no library-level test can
     reach the process entry point. The earlier judgment that MIDIIO
     plumbing tests were "low value while it stays thin" is retracted.
     Both e2e and Engine tests `XCTSkip` when no MIDI server is
     available (headless CI guard).
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
   (starts at login, restarts on crash). Release process per version
   (two commands, two pushes): `packaging/release.sh prepare vX.Y.Z`
   (tests, bump, commit) → `git push` →
   `packaging/release.sh publish vX.Y.Z` (build, sign, notarize, GitHub
   release minting the tag via `--target`, formula rev, sync of
   `~/Projekte/homebrew-tap` — Michael's clone, never the brew-managed
   tap dir) → push the tap (the release-critical push; the formula-rev
   commit here rides with the next ordinary push). If publish fails
   after the GitHub release exists: `packaging/release.sh formula
   vX.Y.Z` finishes the rest.
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
   - **Status:** v0.2.1 (2026-07-13) is the released state — fixes
     hot-plug (dispatchMain ran no CFRunLoop, so setup-change
     notifications never fired), adds plug/unplug and connect-failure
     logging, and lands the test backlog (92 tests incl. the e2e
     subprocess layer); brew-upgraded, service restarted, and log
     verified on Michael's machine. Previous: v0.2.0 (2026-07-12) — adds the
     v0.x latency work (`--measure`, strict `sendAfterMilliseconds`
     timers, idle-time GC, interactive-tier service); upgraded, service
     restarted with the ProcessType Interactive plist, and log verified
     on Michael's machine. Previous: v0.1.1 (2026-07-12) — signed
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

6. **Parameter feedback.** (done — 2026-07-15) Let DAWs send screen-control/parameter feedback
   back through Midimend to the controllers (MainStage "Send Value to" →
   X-Touch Mini LED rings). Mechanism: each virtual output gets a **paired
   virtual destination with the same name** — MainStage pairs
   source/destination by name (verified empirically 2026-07-15), which
   enables its "Send Value to" popup for the Midimend port. Events arriving
   on a paired destination form the *feedback path*: forwarded to the
   configured feedback devices' destinations, and **never** to our own
   virtual sources (loop guard — otherwise the DAW's feedback re-enters it
   as input).
   - **Config:** `"feedback"` in the `midi` section, sibling of
     `inputs`/`outputs`. Either `"all"` — all hardware destinations,
     `ignore` still wins, mirroring the omitted-`inputs` rule — or a list
     of `{ "hardware": … }` specs. Key omitted or empty → no paired
     destinations, exactly today's behavior. Decided: no automatic/implicit
     mode — what Midimend sends must be readable in the config file. But
     `--init` emits `"feedback": "all"`, so the *generated* default is
     feedback-on and explicit: Michael's rigs vary (MiniLab at the desk;
     MP11 + Osmose + XTM; occasional percussion devices and borrowed gear)
     and one config must just work with whatever is plugged in; sending
     feedback to all devices was assessed harmless, and the config line is
     there to narrow if a device ever misbehaves. Feedback is a one-way
     stream with no per-device addressing — routing per controller would
     require one virtual port per controller (postponed; the global list
     upgrades compatibly to a per-output override if that rig ever exists).
   - **Routing (MIDIIO):** the single broadcast send splits into two
     routes — forward (inputs → script → virtual sources + hardware output
     specs) and feedback (paired destinations → feedback destinations).
     Paired destinations get their own receive blocks (per-destination
     tagging); system real-time arriving on the feedback path follows the
     feedback route.
   - **No script on the feedback path** (this iteration): MainStage echoes
     the same CCs a control sends, which is exactly what LED rings expect;
     a feedback/reverse script is parked in IDEAS.md.
   - **Diagnosis:** `--list-devices` shows what `feedback` matches; a
     configured feedback device that isn't present warns at startup like
     inputs/outputs do.
   - **Background (2026-07-15, decoded from a concert's
     `workspace.layout`):** MainStage stores "MIDI Port"
     (`controllerMapping`) and "Send Value to"
     (`outputControllerAssignment`) independently; switching a control's
     port to Midimend Out leaves stale direct-to-device feedback
     assignments *active* while the inspector shows "None (disabled)".
     Migrating users must re-select "Send Value to: Midimend Out" per
     control once the paired destination exists — that overwrites the
     stale entry.
   - **Port name (decided 2026-07-15):** the default virtual port is plain
     **"Midimend"**, not "Midimend Out" — since feedback it is a
     name-paired source/destination duo, and a direction suffix misnames
     one side (hardware sets the precedent: "X-TOUCH MINI" both ways).
     Renamed *before* the first release that ships feedback, so the
     paired name never shipped otherwise. Cost, accepted: unique IDs are
     name-derived, so existing DAW bindings to "Midimend Out" don't
     re-bind — controls must be re-selected once (config names are the
     user's own; only the `--init` default and docs changed).
   - **As implemented:** `FeedbackSpec` (`.all` / `.devices([...])`,
     custom Codable rejecting strings other than `"all"`); an empty
     device list counts as unconfigured, same as omitting the key.
     Matching/diagnosis rules live in `EndpointSelection`
     (`feedback(_:)`, `feedbackConfigured`, `unmatchedFeedbackPatterns`)
     — the pure, shared seam, as before. The feedback route forwards the
     received `MIDIEventList` pointer directly to the feedback
     destinations on the CoreMIDI receive thread: no parse/rebuild, no
     `jsQueue` hop, timestamps preserved, and real-time messages need no
     special-casing. Paired destinations get stable unique IDs (key
     `feedback:<name>`) and are excluded from *all* hardware-destination
     enumeration via `isOwnDestination` — in `"all"` mode a paired
     destination would otherwise match itself and re-enter its own
     handler. `--list-devices` annotates destinations with
     `feedback (matched by …)` / `feedback ("feedback": "all")`.
     E2e-tested: an event sent to the paired destination reaches the
     configured device and does *not* come back out the virtual source.
     Discovered during smoke: `"feedback": "all"` without
     `"ignore": ["DAW"]` reaches DAW-control ports — the example config
     now carries the ignore entry as model practice.
     Verified live (2026-07-15, Michael's rig): MainStage offers
     "Send Value to: Midimend Out", re-selecting it per control fixed the
     stale direct-to-XTM assignments, and the XTM's rings follow —
     including feedback for MiniLab knob turns, which reaches the XTM via
     `"feedback": "all"`.

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
  loop, which never fires on a GCD worker, so without intervention GC
  runs synchronously on allocation thresholds (sub-ms at our heap sizes;
  mitigated: the idle tick now calls `JSGarbageCollect` every 250 ms, so
  collection happens in idle time and thresholds are rarely hit
  mid-event) — and only add a lock-free receive ring if measurement
  says the dispatch hop matters. Also done in v0.x: the brew service
  runs as launchd `ProcessType Interactive` (background tiers coarsen
  timer leeway and scheduling), and `sendAfterMilliseconds` uses a
  strict zero-leeway timer instead of `asyncAfter` (which permits
  coalescing). Measurement exists: `--measure` runs
  normally and prints added-latency percentiles (driver receipt → script
  entry / → processing done) every 10 s, from the driver-receipt
  timestamps CoreMIDI puts on incoming packets. Measured baseline
  (2026-07-12, debug build, MiniLab live): queue hop p50 ≈ 70–140µs,
  worst p99 352µs; total p50 ≈ 200–420µs, p99 < 550µs, one-off 1.2ms
  max in the first window (JIT warmup). An order of magnitude below the
  ~1ms USB-MIDI frame — no receive ring or dedicated thread warranted
  before the v1 tick.
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
