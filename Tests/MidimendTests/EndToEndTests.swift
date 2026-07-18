import XCTest
import CoreMIDI
@testable import MidimendCore

/// End-to-end tests against the real midimend binary. This is the only layer
/// that exercises main.swift — the run-loop choice there once silently killed
/// hot-plug (dispatchMain() runs no CFRunLoop, so CoreMIDI setup-change
/// notifications never fired), invisible to every library-level test.
///
/// Hot-plug is simulated without hardware: creating a virtual CoreMIDI source
/// from this test process triggers `.msgSetupChanged` system-wide, exactly
/// like plugging in a keyboard.
///
/// Skips on machines without a MIDI server (headless CI).
final class EndToEndTests: XCTestCase {

    /// The midimend executable, built next to the test bundle.
    private static var binaryURL: URL {
        Bundle(for: EndToEndTests.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("midimend")
    }

    private var directory: URL!
    private var process: Process?
    private var stdoutPipe: Pipe!
    private let output = OutputCollector()
    private var probeClient = MIDIClientRef()

    /// Accumulates the child's stdout+stderr on a reader queue.
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = ""
        func append(_ text: String) {
            lock.lock()
            storage += text
            lock.unlock()
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.binaryURL.path) else {
            XCTFail("""
            midimend binary not found at \(Self.binaryURL.path) — \
            run `swift build` (swift test builds it as part of the package)
            """)
            return
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("midimend-e2e-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if probeClient != 0 {
            MIDIClientDispose(probeClient)
            probeClient = 0
        }
        if let process, process.isRunning {
            process.interrupt()  // SIGINT — midimend's clean-exit path
            process.waitUntilExit()
        }
        process = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func writeConfigAndScript() throws -> String {
        let script = "function HandleMIDI(e) { Trace(\"e2e: got event\"); e.send(); }"
        try script.write(to: directory.appendingPathComponent("test.js"),
                         atomically: true, encoding: .utf8)
        let virtualOut = "Midimend E2E Out \(ProcessInfo.processInfo.processIdentifier)"
        let config = """
        {
          "script": "test.js",
          "midi": { "outputs": [ { "virtual": "\(virtualOut)" } ] }
        }
        """
        let configPath = directory.appendingPathComponent("config.json").path
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)
        return configPath
    }

    private func launchMidimend(arguments: [String]) throws {
        let process = Process()
        process.executableURL = Self.binaryURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = output
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            output.append(String(decoding: data, as: UTF8.self))
        }
        try process.run()
        self.process = process
        self.stdoutPipe = pipe
    }

    /// Polls the child's output for `fragment`.
    private func expectOutput(
        containing fragment: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if output.text.contains(fragment) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("output containing \"\(fragment)\" not seen within \(timeout)s; output:\n\(output.text)",
                file: file, line: line)
    }

    /// Creates the probe's MIDI client, skipping the test where CoreMIDI is
    /// unavailable (headless CI).
    private func makeProbeClient() throws {
        let status = MIDIClientCreateWithBlock("Midimend E2E Probe" as CFString, &probeClient, nil)
        guard status == noErr else {
            throw XCTSkip("no MIDI server available (MIDIClientCreate: \(status))")
        }
    }

    // MARK: - Tests

    func testVersionFlag() throws {
        try launchMidimend(arguments: ["--version"])
        process?.waitUntilExit()
        XCTAssertEqual(process?.terminationStatus, 0)
        XCTAssertTrue(output.text.hasPrefix("midimend "),
                      "unexpected --version output: \(output.text)")
    }

    /// The keep-awake opt-in is wired through the real run path: a config with
    /// `"keepAwake": true` must build the WakeGuard at startup (announced in the
    /// log), while the default config must not.
    func testKeepAwakeStartupPath() throws {
        try makeProbeClient()
        let script = "function HandleMIDI(e) { e.send(); }"
        try script.write(to: directory.appendingPathComponent("test.js"),
                         atomically: true, encoding: .utf8)
        let virtualOut = "Midimend E2E Wake \(ProcessInfo.processInfo.processIdentifier)"
        let config = """
        {
          "script": "test.js",
          "midi": { "outputs": [ { "virtual": "\(virtualOut)" } ] },
          "keepAwake": true
        }
        """
        let configPath = directory.appendingPathComponent("config.json").path
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)
        try launchMidimend(arguments: [configPath])
        expectOutput(containing: "midimend running")
        expectOutput(containing: "Keeping the display awake")
    }

    /// The regression test for the dispatchMain() bug: a device appearing
    /// after startup must be noticed (setup-change notification delivered),
    /// logged, connected, and its events processed by the script — and its
    /// disappearance logged.
    func testHotPluggedSourceConnectsAndFlowsEndToEnd() throws {
        try makeProbeClient()
        let configPath = try writeConfigAndScript()
        try launchMidimend(arguments: [configPath])
        expectOutput(containing: "midimend running")

        // "Plug in" a device: a virtual source triggers .msgSetupChanged.
        let probeName = "Midimend Hotplug Probe \(ProcessInfo.processInfo.processIdentifier)"
        var probeSource = MIDIEndpointRef()
        let status = MIDISourceCreateWithProtocol(probeClient, probeName as CFString,
                                                  ._1_0, &probeSource)
        guard status == noErr else {
            throw XCTSkip("cannot create virtual source (MIDISourceCreate: \(status))")
        }

        expectOutput(containing: "MIDI input appeared: \(probeName)")
        expectOutput(containing: "Connected input: \(probeName)")

        // Press a key: a NoteOn from the probe must reach the script.
        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        var word: UInt32 = 0x2090_3C64  // MIDI 1.0 channel voice: NoteOn ch1 C4 vel 100
        withUnsafePointer(to: &word) { pointer in
            _ = MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size,
                                 packet, 0, 1, pointer)
        }
        MIDIReceivedEventList(probeSource, &eventList)
        expectOutput(containing: "e2e: got event")

        // "Unplug" it.
        MIDIClientDispose(probeClient)
        probeClient = 0
        expectOutput(containing: "MIDI input disappeared: \(probeName)")
    }

    /// Parameter feedback: a DAW sends values to the virtual output's paired
    /// destination; midimend must forward them to the configured feedback
    /// device — and must NOT emit them on its own virtual source, which
    /// would loop them straight back into the DAW as input.
    func testFeedbackReachesControllerAndDoesNotLoopToDAW() throws {
        try makeProbeClient()

        /// Words received on an endpoint this test owns.
        final class WordCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [UInt32] = []
            func append(_ words: [UInt32]) {
                lock.lock()
                storage += words
                lock.unlock()
            }
            var words: [UInt32] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }
        func collect(_ eventList: UnsafePointer<MIDIEventList>, into collector: WordCollector) {
            for packet in eventList.unsafeSequence() {
                let count = Int(packet.pointee.wordCount)
                collector.append(withUnsafeBytes(of: packet.pointee.words) { raw in
                    Array(raw.bindMemory(to: UInt32.self).prefix(count))
                })
            }
        }

        // The fake controller: a virtual destination owned by this process,
        // where the configured feedback must arrive.
        let controllerName = "Midimend E2E Ctrl \(ProcessInfo.processInfo.processIdentifier)"
        let controllerReceived = WordCollector()
        var controller = MIDIEndpointRef()
        let controllerStatus = MIDIDestinationCreateWithProtocol(
            probeClient, controllerName as CFString, ._1_0, &controller
        ) { eventList, _ in collect(eventList, into: controllerReceived) }
        guard controllerStatus == noErr else {
            throw XCTSkip("cannot create virtual destination (MIDIDestinationCreate: \(controllerStatus))")
        }

        let script = "function HandleMIDI(e) { e.send(); }"
        try script.write(to: directory.appendingPathComponent("test.js"),
                         atomically: true, encoding: .utf8)
        let virtualOut = "Midimend E2E Out \(ProcessInfo.processInfo.processIdentifier)"
        let config = """
        {
          "script": "test.js",
          "midi": {
            "inputs": [],
            "outputs": [ { "virtual": "\(virtualOut)" } ],
            "feedback": [ { "hardware": "\(controllerName)" } ]
          }
        }
        """
        let configPath = directory.appendingPathComponent("config.json").path
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)
        try launchMidimend(arguments: [configPath])
        expectOutput(containing: "midimend running")
        expectOutput(containing: "Feedback outputs: \(controllerName)")

        // The DAW side of the loop guard: listen on midimend's virtual source.
        let dawReceived = WordCollector()
        var listenPort = MIDIPortRef()
        XCTAssertEqual(MIDIInputPortCreateWithProtocol(
            probeClient, "e2e listen" as CFString, ._1_0, &listenPort
        ) { eventList, _ in collect(eventList, into: dawReceived) }, noErr)

        func findEndpoint(named name: String, count: Int, get: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef? {
            (0..<count).map(get).first { $0 != 0 && midiDisplayName($0) == name }
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        var pairedDestination = MIDIEndpointRef()
        var virtualSource = MIDIEndpointRef()
        while Date() < deadline, pairedDestination == 0 || virtualSource == 0 {
            pairedDestination = findEndpoint(named: virtualOut, count: MIDIGetNumberOfDestinations(),
                                             get: MIDIGetDestination) ?? 0
            virtualSource = findEndpoint(named: virtualOut, count: MIDIGetNumberOfSources(),
                                         get: MIDIGetSource) ?? 0
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertNotEqual(pairedDestination, 0,
                          "no destination named \(virtualOut) — paired destination not created")
        XCTAssertNotEqual(virtualSource, 0)
        XCTAssertEqual(MIDIPortConnectSource(listenPort, virtualSource, nil), noErr)

        // "MainStage sends feedback": CC 20 value 64 to the paired destination.
        var sendPort = MIDIPortRef()
        XCTAssertEqual(MIDIOutputPortCreate(probeClient, "e2e send" as CFString, &sendPort), noErr)
        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        var word: UInt32 = 0x20B0_1440  // MIDI 1.0 channel voice: CC ch1 #20 val 64
        withUnsafePointer(to: &word) { pointer in
            _ = MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size,
                                 packet, 0, 1, pointer)
        }
        XCTAssertEqual(MIDISendEventList(sendPort, pairedDestination, &eventList), noErr)

        // Must arrive at the controller...
        let receiveDeadline = Date(timeIntervalSinceNow: 5)
        while Date() < receiveDeadline, !controllerReceived.words.contains(0x20B0_1440) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(controllerReceived.words.contains(0x20B0_1440),
                      "feedback event did not reach the controller; got \(controllerReceived.words)")

        // ...and must NOT have come back out of the virtual source.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(dawReceived.words.isEmpty,
                      "feedback looped back to the DAW side: \(dawReceived.words)")
    }
}
