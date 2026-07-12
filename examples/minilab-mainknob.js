// Remap the Arturia MiniLab MainKnob (one relative CC) to two separate CCs
// that MainStage can map to "previous patch" / "next patch".
//
// Adjust "Source CC" (and the direction split below) to what your knob
// actually sends — a quick `event.trace()` in HandleMIDI shows it.
//
// The script runs unchanged inside the Scripter plug-in in Logic Pro or
// MainStage for testing.

var PluginParameters = [
    { name: "Source Patch CC", type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 16 },
    { name: "CC Prev Patch",   type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 110 },
    { name: "CC Next Patch",   type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 111 },
    { name: "Source Set CC", type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 17 },
    { name: "CC Prev Set",   type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 112 },
    { name: "CC Next Set",   type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 113 },
];

function HandleMIDI(event) {
    if (event instanceof ControlChange) {
        if (event.number == GetParameter("Source Patch CC")) {
            // Relative encoding: values below 64 = increment, 64 and above = decrement.
            var out = new ControlChange(event);
            out.number = (event.value < 64) ? GetParameter("CC Prev Patch") : GetParameter("CC Next Patch");
            out.value = 127;
            out.send();
        } else if (event.number == GetParameter("Source Set CC")) {
            // Relative encoding: values below 64 = increment, 64 and above = decrement.
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
