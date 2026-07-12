import XCTest
@testable import Midimend

/// Thread-safe recorder for everything a script emits.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [MIDIEventBytes] = []
    private var _traces: [String] = []
    private var _delays: [Double] = []

    var sent: [MIDIEventBytes] { lock.lock(); defer { lock.unlock() }; return _sent }
    var traces: [String] { lock.lock(); defer { lock.unlock() }; return _traces }
    var delays: [Double] { lock.lock(); defer { lock.unlock() }; return _delays }

    func send(_ event: MIDIEventBytes) { lock.lock(); _sent.append(event); lock.unlock() }
    func trace(_ message: String) { lock.lock(); _traces.append(message); lock.unlock() }
    func delay(_ ms: Double) { lock.lock(); _delays.append(ms); lock.unlock() }
}

final class ScriptEngineTests: XCTestCase {

    private func makeEngine(
        _ script: String,
        parameters: [String: ParameterValue] = [:],
        recorder: Recorder
    ) throws -> ScriptEngine {
        try ScriptEngine(
            script: script,
            scriptName: "test.js",
            configParameters: parameters,
            send: { recorder.send($0) },
            trace: { recorder.trace($0) },
            schedule: { delayMs, action in
                recorder.delay(delayMs)
                action() // run scheduled sends immediately in tests
            }
        )
    }

    func testPassThroughWithoutHandleMIDI() throws {
        let recorder = Recorder()
        let engine = try makeEngine("// no handlers defined", recorder: recorder)
        let noteOn = MIDIEventBytes(status: 0x90, data1: 60, data2: 100)
        engine.handleIncoming(noteOn)
        XCTAssertEqual(recorder.sent, [noteOn])
    }

    func testTransposePreservesChannel() throws {
        let recorder = Recorder()
        let engine = try makeEngine("""
            function HandleMIDI(event) {
                if (event instanceof NoteOn || event instanceof NoteOff) {
                    event.pitch += 12;
                }
                event.send();
            }
            """, recorder: recorder)
        engine.handleIncoming(MIDIEventBytes(status: 0x91, data1: 60, data2: 100))
        engine.handleIncoming(MIDIEventBytes(status: 0x81, data1: 60, data2: 0))
        engine.handleIncoming(MIDIEventBytes(status: 0xB1, data1: 1, data2: 42))
        XCTAssertEqual(recorder.sent, [
            MIDIEventBytes(status: 0x91, data1: 72, data2: 100),
            MIDIEventBytes(status: 0x81, data1: 72, data2: 0),
            MIDIEventBytes(status: 0xB1, data1: 1, data2: 42),
        ])
    }

    func testMiniLabRemapWithConfigOverride() throws {
        let recorder = Recorder()
        let engine = try makeEngine("""
            var PluginParameters = [
                { name: "Source CC", type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 28 },
                { name: "CC Next",   type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 110 },
                { name: "CC Prev",   type: "lin", minValue: 0, maxValue: 127, numberOfSteps: 127, defaultValue: 111 },
            ];
            function HandleMIDI(event) {
                if (event instanceof ControlChange && event.number == GetParameter("Source CC")) {
                    var out = new ControlChange(event);
                    out.number = (event.value < 64) ? GetParameter("CC Next") : GetParameter("CC Prev");
                    out.value = 127;
                    out.send();
                } else {
                    event.send();
                }
            }
            """,
            parameters: ["Source CC": .number(29)],
            recorder: recorder)

        engine.handleIncoming(MIDIEventBytes(status: 0xB0, data1: 29, data2: 1))   // knob turned right
        engine.handleIncoming(MIDIEventBytes(status: 0xB0, data1: 29, data2: 65))  // knob turned left
        engine.handleIncoming(MIDIEventBytes(status: 0xB0, data1: 28, data2: 3))   // unrelated CC passes through
        XCTAssertEqual(recorder.sent, [
            MIDIEventBytes(status: 0xB0, data1: 110, data2: 127),
            MIDIEventBytes(status: 0xB0, data1: 111, data2: 127),
            MIDIEventBytes(status: 0xB0, data1: 28, data2: 3),
        ])
    }

    func testMenuParameterAcceptsValueString() throws {
        let recorder = Recorder()
        let engine = try makeEngine("""
            var PluginParameters = [
                { name: "Mode", type: "menu", valueStrings: ["Off", "On", "Auto"], defaultValue: 0 },
            ];
            """,
            parameters: ["Mode": .string("Auto")],
            recorder: recorder)
        XCTAssertEqual(engine.currentValue(named: "Mode"), 2)
    }

    func testParameterChangedFiresOnLoadWithConfigValue() throws {
        let recorder = Recorder()
        _ = try makeEngine("""
            var PluginParameters = [
                { name: "Gate", type: "lin", minValue: 0, maxValue: 1, defaultValue: 0.5 },
            ];
            function ParameterChanged(index, value) {
                Trace("pc:" + index + ":" + value);
            }
            """,
            parameters: ["Gate": .number(0.8)],
            recorder: recorder)
        XCTAssertTrue(recorder.traces.contains("pc:0:0.8"), "traces were: \(recorder.traces)")
    }

    func testSendAfterMillisecondsUsesScheduler() throws {
        let recorder = Recorder()
        let engine = try makeEngine("""
            function HandleMIDI(event) {
                event.sendAfterMilliseconds(100);
            }
            """, recorder: recorder)
        engine.handleIncoming(MIDIEventBytes(status: 0x90, data1: 64, data2: 80))
        XCTAssertEqual(recorder.delays, [100])
        XCTAssertEqual(recorder.sent, [MIDIEventBytes(status: 0x90, data1: 64, data2: 80)])
    }

    func testNoteOffCloneFromNoteOn() throws {
        let recorder = Recorder()
        let engine = try makeEngine("""
            function HandleMIDI(event) {
                if (event instanceof NoteOn) {
                    var off = new NoteOff(event);
                    off.send();
                }
            }
            """, recorder: recorder)
        engine.handleIncoming(MIDIEventBytes(status: 0x92, data1: 64, data2: 100))
        XCTAssertEqual(recorder.sent, [MIDIEventBytes(status: 0x82, data1: 64, data2: 100)])
    }

    func testMIDIUtilityObject() throws {
        let recorder = Recorder()
        _ = try makeEngine("""
            Trace(MIDI.noteName(60));
            Trace(MIDI.noteNumber("C3"));
            Trace(MIDI.ccName(64));
            Trace(MIDI.normalizeData(200));
            """, recorder: recorder)
        XCTAssertEqual(Array(recorder.traces.prefix(4)), ["C3", "60", "Sustain", "127"])
    }

    func testAllNotesOffSendsOnAllSixteenChannels() throws {
        let recorder = Recorder()
        _ = try makeEngine("MIDI.allNotesOff();", recorder: recorder)
        XCTAssertEqual(recorder.sent.count, 16)
        XCTAssertEqual(recorder.sent.first, MIDIEventBytes(status: 0xB0, data1: 123, data2: 0))
        XCTAssertEqual(recorder.sent.last, MIDIEventBytes(status: 0xBF, data1: 123, data2: 0))
    }

    // idleTick also collects garbage; live state must survive collections.
    func testIdleTickRunsIdleCallbackAndPreservesLiveState() throws {
        let recorder = Recorder()
        let engine = try makeEngine("""
            var held = { pitch: 60 };
            var idles = 0;
            function Idle() {
                idles++;
                var garbage = [];
                for (var i = 0; i < 10000; i++) garbage.push({ i: i });
            }
            function HandleMIDI(event) {
                event.pitch = held.pitch + idles;
                event.send();
            }
            """, recorder: recorder)
        for _ in 0..<5 { engine.idleTick() }
        engine.handleIncoming(MIDIEventBytes(status: 0x90, data1: 0, data2: 100))
        XCTAssertEqual(recorder.sent, [MIDIEventBytes(status: 0x90, data1: 65, data2: 100)])
    }

    func testScriptSyntaxErrorThrows() {
        let recorder = Recorder()
        XCTAssertThrowsError(try makeEngine("function HandleMIDI(event) {", recorder: recorder))
    }

    func testRuntimeExceptionIsContained() throws {
        let recorder = Recorder()
        let engine = try makeEngine("""
            function HandleMIDI(event) {
                nonexistentFunction();
            }
            """, recorder: recorder)
        engine.handleIncoming(MIDIEventBytes(status: 0x90, data1: 60, data2: 100))
        XCTAssertTrue(recorder.traces.contains { $0.hasPrefix("[JS Exception]") },
                      "traces were: \(recorder.traces)")
        XCTAssertEqual(recorder.sent, []) // event dropped, process alive
    }
}
