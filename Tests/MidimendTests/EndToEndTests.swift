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
}
