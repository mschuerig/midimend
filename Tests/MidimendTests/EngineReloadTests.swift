import XCTest
@testable import Midimend

/// The Engine's hot-reload path: script/config rewrites trigger a reload
/// (including across atomic saves, which replace the watched file), a broken
/// script keeps the previous one, and a changed `midi` section only notes
/// that a restart is needed.
///
/// These tests create real (uniquely named) CoreMIDI virtual ports; they skip
/// on machines without a MIDI server (headless CI).
final class EngineReloadTests: XCTestCase {

    /// Thread-safe log sink the Engine's @Sendable log closure can write to.
    private final class LogCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }
        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        func removeAll() {
            lock.lock()
            storage.removeAll()
            lock.unlock()
        }
    }

    private var directory: URL!
    private var scriptURL: URL!
    private var configURL: URL!
    private let log = LogCollector()
    private var engine: Engine?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("midimend-engine-tests-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        scriptURL = directory.appendingPathComponent("test.js")
        configURL = directory.appendingPathComponent("config.json")
    }

    override func tearDown() {
        engine = nil
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Helpers

    private func writeScript(_ source: String) throws {
        try source.write(to: scriptURL, atomically: true, encoding: .utf8)
    }

    private func writeConfig(virtualOut: String? = nil) throws {
        let out = virtualOut ?? "Midimend Test \(ProcessInfo.processInfo.processIdentifier)"
        let json = """
        {
          "script": "test.js",
          "midi": { "outputs": [ { "virtual": "\(out)" } ] }
        }
        """
        try json.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func startEngine() throws {
        let log = log
        do {
            let engine = try Engine(configPath: configURL.path, log: { log.append($0) })
            try engine.start()
            self.engine = engine
        } catch MidimendError.midi(let what, let status) {
            throw XCTSkip("no MIDI server available (\(what): \(status))")
        }
    }

    /// Polls the collected log for a line containing `fragment`.
    private func waitForLog(
        containing fragment: String,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if log.lines.contains(where: { $0.contains(fragment) }) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("log line containing \"\(fragment)\" not seen within \(timeout)s; log: \(log.lines)",
                file: file, line: line)
    }

    // MARK: - Tests

    func testScriptRewriteReloads() throws {
        try writeScript("function HandleMIDI(e) { e.send(); }")
        try writeConfig()
        try startEngine()
        waitForLog(containing: "Script evaluated successfully!")

        try writeScript("function HandleMIDI(e) { /* v2 */ e.send(); }")
        waitForLog(containing: "Reloaded test.js")
    }

    func testBrokenScriptKeepsPreviousAndRecovers() throws {
        try writeScript("function HandleMIDI(e) { e.send(); }")
        try writeConfig()
        try startEngine()
        waitForLog(containing: "Script evaluated successfully!")

        try writeScript("function HandleMIDI(e) { syntax error {{{")
        waitForLog(containing: "keeping previous script")

        // The watcher must have re-armed on the failed reload, too.
        try writeScript("function HandleMIDI(e) { /* fixed */ e.send(); }")
        waitForLog(containing: "Reloaded test.js")
    }

    func testChangedMIDISectionAsksForRestart() throws {
        try writeScript("function HandleMIDI(e) { e.send(); }")
        try writeConfig()
        try startEngine()
        waitForLog(containing: "Script evaluated successfully!")

        try writeConfig(virtualOut: "Midimend Test Other \(ProcessInfo.processInfo.processIdentifier)")
        waitForLog(containing: "restart to apply")
    }

    func testConsecutiveAtomicSavesEachReload() throws {
        // .write(atomically: true) replaces the file (rename), invalidating
        // the watched descriptor — the re-arm after each reload is what keeps
        // the second save working.
        try writeScript("function HandleMIDI(e) { e.send(); }")
        try writeConfig()
        try startEngine()
        waitForLog(containing: "Script evaluated successfully!")

        try writeScript("function HandleMIDI(e) { Trace('v2'); e.send(); }")
        waitForLog(containing: "Reloaded test.js")

        log.removeAll()

        try writeScript("function HandleMIDI(e) { Trace('v3'); e.send(); }")
        waitForLog(containing: "Reloaded test.js")
    }
}
