# Midimend

Mend your MIDI before the DAW sees it.

Hardware controllers don't always speak the dialect your software wants.
A knob sends one relative CC where your DAW needs two distinct buttons; a
pedal sends the wrong controller number; a keyboard's messages almost fit,
but not quite. Inside Logic Pro and MainStage there is no global fix:
MIDI-processing plug-ins are always bound to a single track or channel
strip. Midimend sits in front of the DAW instead — it connects to your MIDI
sources, runs a small JavaScript processing script per event, and emits the
mended stream on a virtual output port that the DAW uses as its input.

Scripts use the same JavaScript API as the Scripter MIDI plug-in, so existing
scripts run unchanged, and scripts developed here can be tested inside the
plug-in — including the same underlying engine (the system JavaScriptCore
framework).

No GUI — configuration is a JSON file.

Status: **v0** — the host-independent part of the scripting API (see
[PLANNING.md](PLANNING.md) for the roadmap).

## Example: one knob, but the DAW wants two buttons

The motivating case: the Arturia MiniLab's main knob sends a *single*
relative CC — direction is encoded in the value — but MainStage's
*previous patch* / *next patch* actions each need their own CC. No amount
of mapping fixes that. [examples/minilab-mainknob.js](examples/minilab-mainknob.js)
mends it: the one relative CC becomes two distinct CCs (value 127), which
[examples/config.example.json](examples/config.example.json) feeds to
MainStage. The prev/next patch and set buttons in MainStage's stock
layouts aren't mapped to any CC out of the box — map them to these CCs
in Assignments & Mappings.

## Install & run

```sh
brew install mschuerig/tap/midimend
brew services start midimend    # runs now and at every login
```

The service runs `midimend` without arguments, which reads
`~/Music/Midimend/config.json` — a visible folder to keep your config
and scripts in, next to where Logic/MainStage users already keep their
content. Requires macOS 13+. No entitlements or permissions needed.

To start a config for a script, generate a skeleton with the script's
parameter defaults filled in, then set the input device name:

```sh
midimend --init your-script.js > ~/Music/Midimend/config.json
```

To see what's connected — and, given a config, what it matches:

```sh
midimend --list-devices
midimend --list-devices ~/Music/Midimend/config.json
```

If a configured device isn't present at startup, midimend warns and lists
the devices that are, then connects the device automatically when it
appears. The service's output lands in `/opt/homebrew/var/log/midimend.log`.

To build from source instead:

```sh
swift build -c release
.build/release/midimend examples/config.example.json
```

## Configuration

```jsonc
{
  "script": "minilab-mainknob.js",        // path, absolute or relative to this file
  "midi": {
    "inputs": [
      { "hardware": "MiniLab" },          // connect to sources matching this name (substring)
      { "virtual": "Midimend In" }        // create a virtual port other apps can send to
    ],
    "outputs": [
      { "virtual": "Midimend" }           // virtual port; select as input in your DAW
      // { "hardware": "some device" }    // ...or send to a hardware destination
    ],
    "feedback": "all",                    // return the DAW's parameter feedback to all devices
                                          // ("all", or a device list like "inputs"; omit to disable)
    "ignore": ["DAW"]                     // devices to leave alone entirely (substring match)
  },
  "parameters": {                          // values for the script's PluginParameters, by name
    "Source CC": 28,                       // numbers for sliders
    "Mode": "Auto",                        // menu parameters accept the valueStrings entry
    "Enabled": true                        // checkboxes accept booleans
  }
}
```

Omit `"inputs"` entirely to connect *all* MIDI devices (except ignored ones
and Midimend's own virtual ports). Devices are connected when they appear,
so plugging in a controller after startup just works. Use `"ignore"` for
endpoints Midimend should neither read nor send to — typically a
controller's DAW-control port (e.g. "Minilab37 DAW" next to
"Minilab37 MIDI"), which talks to the DAW directly.

Parameter *definitions* live in the script's `PluginParameters` array (the
usual convention); the config supplies *values*. Config and script files are
watched — saving either hot-reloads the script and re-fires
`ParameterChanged` for every parameter, like loading a plug-in setting.
Changing the `midi` section requires a restart.

In MainStage, set your layout objects' MIDI input to the virtual output port
(e.g. "Midimend") so the raw hardware events are ignored; in Logic,
use the track inspector's MIDI In Port. Do this *before* using Learn — Learn
binds to whichever port's message arrives first.

### Parameter feedback

Controllers with LED rings, button lights, or motor faders expect the DAW
to send values *back* — e.g. so encoder rings show the parameter after a
patch change. With `"feedback"` configured, each virtual output gets a
same-named companion port that DAWs can send to; whatever arrives there is
passed through, unchanged, to the feedback devices — `"all"` (every device
except ignored ones) or an explicit list like
`[{ "hardware": "X-TOUCH" }]`. Omit the key and neither the companion port
nor the feedback path exists.

In MainStage, choose the virtual port (e.g. "Midimend") as the screen
control's **Send Value to** in layout mode. If a control's feedback used to
go to the hardware port directly, re-select its "Send Value to" after
switching — MainStage keeps the old feedback route active even though the
popup shows "None" for it.

## Supported script API (v0)

| Area | Status |
|---|---|
| `HandleMIDI(event)`, per-type handlers (`HandleNote`, `HandleControlChange`, …) | ✅ |
| Event classes: `NoteOn`, `NoteOff`, `PolyPressure`, `ControlChange`, `ProgramChange`, `ChannelPressure`, `PitchBend` (+ clone constructors, `pitch`/`velocity`/`number`/`value` accessors) | ✅ |
| `event.send()`, `event.sendAfterMilliseconds(ms)`, `event.trace()`, `event.toString()` | ✅ |
| `MIDI` object: `noteName`, `noteNumber`, `ccName`, `allNotesOff`, `normalize*` | ✅ |
| `PluginParameters` (`lin`/`log`/`menu`/`checkbox`/`momentary`/`text`), `GetParameter`, `SetParameter`, `ParameterChanged` | ✅ (values from config; `hidden`/`readOnly`/`disableAutomation` accepted, ignored) |
| `Trace()` | ✅ (stdout, no thinning) |
| `Idle()` | ✅ (every 0.25 s) |
| Runtime exceptions | contained per callback and logged |
| System real-time/common messages (clock, start/stop) | passed through unmodified |
| `sendAtBeat()`, `sendAfterBeats()` | ⚠️ no transport yet — warns once, sends immediately |
| `GetTimingInfo()`, `NeedsTimingInfo`, `beatPos` | ⚠️ no transport yet — `undefined` / 0, with warning |
| `ProcessMIDI()`, `Reset()` | ⚠️ not called yet (arrive with the transport in v1) |
| `TargetEvent`, `type:"target"` parameters | ❌ host-specific — events dropped with a warning |
| `articulationID`, `port`, `isRealtime`, `beatPos` properties | present on events; pass-through values |

Known deviations: `toString()` output and CC names may differ in wording from
the original plug-in's; constructor default values (`new NoteOn()` without
arguments) are not verified yet.

## Testing

```sh
swift test
```

The test suite exercises the script engine without CoreMIDI (events in,
recorded events out), so it runs anywhere.

## Roadmap

- **v1 — timing**: internal transport (tempo/meter from config), `TimingInfo`,
  `beatPos`, beat-domain scheduler for `sendAtBeat`/`sendAfterBeats`,
  `ProcessMIDI` tick, `Reset`.
- **v1.x — sync**: MIDI Clock slave (Start/Stop/SPP), maybe Ableton Link.
- See [PLANNING.md](PLANNING.md) for details and design notes, and
  [IDEAS.md](IDEAS.md) for deliberately postponed features.
