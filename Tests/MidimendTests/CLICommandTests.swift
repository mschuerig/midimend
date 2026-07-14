import XCTest
@testable import MidimendCore

/// The CLI's argument grammar, extracted from main.swift so it can be
/// tested without spawning the binary. Side effects (default-config
/// resolution, printing, exiting) stay in main.swift.
final class CLICommandTests: XCTestCase {

    // MARK: - Run

    func testNoArgumentsRunsDefaultConfig() {
        XCTAssertEqual(CLICommand.parse([]), .run(configPath: nil, measure: false))
    }

    func testConfigPathArgumentRunsThatConfig() {
        XCTAssertEqual(CLICommand.parse(["my.json"]), .run(configPath: "my.json", measure: false))
    }

    func testExtraRunArgumentsAreAUsageError() {
        XCTAssertEqual(CLICommand.parse(["a.json", "b.json"]), .usageError)
    }

    // MARK: - --measure

    func testMeasureWithoutConfigUsesDefault() {
        XCTAssertEqual(CLICommand.parse(["--measure"]), .run(configPath: nil, measure: true))
    }

    func testMeasureWithConfig() {
        XCTAssertEqual(CLICommand.parse(["--measure", "my.json"]),
                       .run(configPath: "my.json", measure: true))
    }

    func testMeasureWithExtraArgumentsIsAUsageError() {
        XCTAssertEqual(CLICommand.parse(["--measure", "a.json", "b.json"]), .usageError)
    }

    // MARK: - --list-devices

    func testListDevicesWithoutConfig() {
        XCTAssertEqual(CLICommand.parse(["--list-devices"]), .listDevices(configPath: nil))
    }

    func testListDevicesWithConfig() {
        XCTAssertEqual(CLICommand.parse(["--list-devices", "my.json"]),
                       .listDevices(configPath: "my.json"))
    }

    func testListDevicesWithExtraArgumentsIsAUsageError() {
        XCTAssertEqual(CLICommand.parse(["--list-devices", "a.json", "b.json"]), .usageError)
    }

    // MARK: - --init

    func testInitRequiresExactlyOneScript() {
        XCTAssertEqual(CLICommand.parse(["--init", "s.js"]), .initTemplate(scriptPath: "s.js"))
        XCTAssertEqual(CLICommand.parse(["--init"]), .usageError)
        XCTAssertEqual(CLICommand.parse(["--init", "a.js", "b.js"]), .usageError)
    }

    // MARK: - --version, help, unknown options

    func testVersionAndHelp() {
        XCTAssertEqual(CLICommand.parse(["--version"]), .version)
        XCTAssertEqual(CLICommand.parse(["-h"]), .help)
        XCTAssertEqual(CLICommand.parse(["--help"]), .help)
    }

    func testUnknownOptionIsAUsageError() {
        XCTAssertEqual(CLICommand.parse(["-x"]), .usageError)
        XCTAssertEqual(CLICommand.parse(["--bogus"]), .usageError)
    }
}

/// The --list-devices output lines, one section at a time: verdict
/// annotations per device plus trailing unmatched-pattern diagnoses.
final class DeviceLinesTests: XCTestCase {

    func testAnnotatesVerdictsAndMissingPatterns() {
        let lines = deviceLines(
            title: "MIDI inputs (sources)",
            names: ["Minilab37 MIDI", "Minilab37 DAW", "Launchkey 49"],
            verdict: { name in
                switch name {
                case "Minilab37 MIDI": .connected(pattern: "Minilab")
                case "Minilab37 DAW": .ignored(pattern: "DAW")
                default: .notMatched
                }
            },
            missing: ["Synth"]
        )
        XCTAssertEqual(lines, [
            "MIDI inputs (sources):",
            "  Minilab37 MIDI  — matched by \"Minilab\"",
            "  Minilab37 DAW  — ignored by \"DAW\"",
            "  Launchkey 49",
            "  (nothing matches \"Synth\")",
        ])
    }

    func testDefaultAllInputsAnnotation() {
        let lines = deviceLines(
            title: "MIDI inputs (sources)",
            names: ["Minilab37 MIDI"],
            verdict: { _ in .connected(pattern: nil) },
            missing: []
        )
        XCTAssertEqual(lines, [
            "MIDI inputs (sources):",
            "  Minilab37 MIDI  — connected (no \"inputs\" in config: all devices)",
        ])
    }

    // MARK: - Feedback annotations (destinations section)

    func testFeedbackListAnnotation() {
        let lines = deviceLines(
            title: "MIDI outputs (destinations)",
            names: ["X-TOUCH MINI", "Minilab37 MIDI"],
            verdict: { _ in .notMatched },
            feedback: { name in
                name == "X-TOUCH MINI" ? .connected(pattern: "X-TOUCH") : .notMatched
            },
            missing: []
        )
        XCTAssertEqual(lines, [
            "MIDI outputs (destinations):",
            "  X-TOUCH MINI  — feedback (matched by \"X-TOUCH\")",
            "  Minilab37 MIDI",
        ])
    }

    func testFeedbackAllAnnotation() {
        let lines = deviceLines(
            title: "MIDI outputs (destinations)",
            names: ["X-TOUCH MINI", "Minilab37 DAW"],
            verdict: { _ in .notMatched },
            feedback: { name in
                name == "Minilab37 DAW" ? .ignored(pattern: "DAW") : .connected(pattern: nil)
            },
            missing: []
        )
        XCTAssertEqual(lines, [
            "MIDI outputs (destinations):",
            "  X-TOUCH MINI  — feedback (\"feedback\": \"all\")",
            "  Minilab37 DAW",
        ])
    }

    func testForwardOutputAndFeedbackAnnotationsCombine() {
        let lines = deviceLines(
            title: "MIDI outputs (destinations)",
            names: ["Synth"],
            verdict: { _ in .connected(pattern: "Synth") },
            feedback: { _ in .connected(pattern: nil) },
            missing: []
        )
        XCTAssertEqual(lines, [
            "MIDI outputs (destinations):",
            "  Synth  — matched by \"Synth\", feedback (\"feedback\": \"all\")",
        ])
    }

    func testNoDevicesAndNoConfig() {
        XCTAssertEqual(
            deviceLines(title: "MIDI outputs (destinations)", names: [], verdict: nil, missing: []),
            ["MIDI outputs (destinations):", "  (none)"]
        )
    }
}
