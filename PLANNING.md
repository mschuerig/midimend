# Planning

Living document: near-term plan, roadmap, and the design notes behind them.
Deliberately postponed features live in [IDEAS.md](IDEAS.md) with their own
design notes.

**Guiding principle:** easy to use for non-technical users (most musicians) —
as few surprises as possible, and problems must be easy to diagnose.

## Now (v0.x) — toward a first release

1. **Diagnosis basics.** A device-listing command (`--list-devices` or
   `doctor`); when a configured device isn't found, print the devices that
   *are* present instead of failing bare.
2. **Config template generation.** `midimend --init script.js` evaluates the
   script's `PluginParameters` and prints a config skeleton with defaults
   filled in.
3. **Device robustness.** Default to all inputs when `inputs` is omitted
   (excluding our own virtual ports — feedback-loop guard); connect
   hot-plugged devices via the existing setup-change notification; match
   display names as well as endpoint names (users rename devices in
   Audio MIDI Setup).
4. **Publish.** GitHub repo `midimend`; license: No-Rights-Reserved/CC0 with
   AI-authorship note; homebrew formula in `mschuerig/homebrew-tap` building
   from source, with a `service` block so `brew services start midimend`
   answers "how does the app run" (starts at login, restarts on crash).

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

- **Threading:** the `JSVirtualMachine` lives on a dedicated JS thread;
  CoreMIDI receive callbacks only enqueue into a ring buffer. All JS access
  (events, timer ticks, config reloads) stays on that one thread.
- **Port persistence:** set `kMIDIPropertyUniqueID` on virtual ports so other
  apps' saved connections re-bind across restarts.
- **Receiver-side suppression:** CoreMIDI has no exclusive capture; DAWs must
  ignore raw hardware via input-port selection (documented in the README).
- **iOS (distant):** keep the core platform-neutral (engine + scheduler +
  transport, no I/O assumptions). Virtual endpoints on iOS require
  `UIBackgroundModes: audio` and an app shell; JSC runs interpreter-only
  there — irrelevant at MIDI rates.
