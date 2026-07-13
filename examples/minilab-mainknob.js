// Remap the Arturia MiniLab MainKnob (one relative CC) to two separate CCs
// that MainStage can map to "previous patch" / "next patch".
//
// Defaults match the MiniLab 3 factory program: the MainKnob sends CC 114
// (patch mode) or CC 112 (set mode). Each detent produces a value-64
// message followed by 65 (clockwise) or 62 (counterclockwise); the value-64
// messages carry no direction and are dropped. If you use your own program,
// adjust the source CCs — a quick `event.trace()` in HandleMIDI shows what
// your knob actually sends.
//
// MainStage side: the prev/next patch and set buttons present in most stock
// layouts are NOT mapped to any CC out of the box. Open Assignments &
// Mappings and map each button to the corresponding output CC below.
//
// The script runs unchanged inside the Scripter plug-in in Logic Pro or
// MainStage for testing.

var PluginParameters = [
    { name: "Source Patch CC", type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 114 },
    { name: "CC Prev Patch",   type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 110 },
    { name: "CC Next Patch",   type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 111 },
    { name: "Source Set CC", type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 112 },
    { name: "CC Prev Set",   type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 115 },
    { name: "CC Next Set",   type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 116 },
];

function HandleMIDI(event) {
    if (event instanceof ControlChange) {
        if (event.number == GetParameter("Source Patch CC")) {
            // Relative encoding: 65 = clockwise (next), 62 = counterclockwise
            // (prev). Value 64 means "no movement" — the factory program sends
            // it before every real step — so drop it.
            if (event.value == 64) return;
            var out = new ControlChange(event);
            out.number = (event.value < 64) ? GetParameter("CC Prev Patch") : GetParameter("CC Next Patch");
            out.value = 127;
            out.send();
        } else if (event.number == GetParameter("Source Set CC")) {
            if (event.value == 64) return;
            var out = new ControlChange(event);
            out.number = (event.value < 64) ? GetParameter("CC Prev Set") : GetParameter("CC Next Set");
            out.value = 127;
            out.send();
        } else {
          event.send();
        }
    } else {
        event.send();
    }
}
