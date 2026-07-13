import XCTest
@testable import MidimendCore

/// The config's device-selection rules: explicit `hardware` patterns,
/// default-all-inputs when `inputs` is omitted, and the `ignore` list
/// (which wins over both).
final class EndpointSelectionTests: XCTestCase {

    private func selection(
        inputs: [String]? = [],
        outputs: [String] = [],
        ignore: [String] = []
    ) -> EndpointSelection {
        EndpointSelection(
            setup: MIDISetup(
                inputs: inputs.map { $0.map { EndpointSpec(hardware: $0) } },
                outputs: outputs.map { EndpointSpec(hardware: $0) },
                ignore: ignore.isEmpty ? nil : ignore
            )
        )
    }

    // MARK: - Explicit input patterns

    func testExplicitPatternConnectsMatchingInput() {
        let selection = selection(inputs: ["Minilab"])
        XCTAssertEqual(selection.input("Minilab37 MIDI"), .connected(pattern: "Minilab"))
        XCTAssertEqual(selection.input("Launchkey 49"), .notMatched)
    }

    func testIgnoreWinsOverExplicitMatch() {
        let selection = selection(inputs: ["Minilab"], ignore: ["DAW"])
        XCTAssertEqual(selection.input("Minilab37 MIDI"), .connected(pattern: "Minilab"))
        XCTAssertEqual(selection.input("Minilab37 DAW"), .ignored(pattern: "DAW"))
    }

    func testEmptyInputListConnectsNothing() {
        let selection = selection(inputs: [])
        XCTAssertEqual(selection.input("Minilab37 MIDI"), .notMatched)
    }

    // MARK: - Default-all-inputs mode (inputs omitted)

    func testOmittedInputsConnectEverything() {
        let selection = selection(inputs: nil)
        XCTAssertEqual(selection.input("Minilab37 MIDI"), .connected(pattern: nil))
        XCTAssertEqual(selection.input("IAC Driver Bus 1"), .connected(pattern: nil))
    }

    func testOmittedInputsStillHonorIgnore() {
        let selection = selection(inputs: nil, ignore: ["DAW"])
        XCTAssertEqual(selection.input("Minilab37 MIDI"), .connected(pattern: nil))
        XCTAssertEqual(selection.input("Minilab37 DAW"), .ignored(pattern: "DAW"))
    }

    // MARK: - Outputs (never default-all)

    func testOutputsMatchExplicitlyAndHonorIgnore() {
        let selection = selection(outputs: ["Minilab"], ignore: ["DAW"])
        XCTAssertEqual(selection.output("Minilab37 MIDI"), .connected(pattern: "Minilab"))
        XCTAssertEqual(selection.output("Minilab37 DAW"), .ignored(pattern: "DAW"))
        XCTAssertEqual(selection.output("Launchkey 49"), .notMatched)
    }

    func testIgnoreMatchingIsCaseInsensitiveSubstring() {
        let selection = selection(inputs: nil, ignore: ["daw"])
        XCTAssertEqual(selection.input("Minilab37 DAW"), .ignored(pattern: "daw"))
    }

    // MARK: - Unmatched-pattern diagnosis

    func testUnmatchedPatternsListsPatternsNoDeviceSatisfies() {
        let selection = selection(inputs: ["Minilab", "Launchkey"])
        XCTAssertEqual(
            selection.unmatchedInputPatterns(among: ["Minilab37 MIDI", "IAC Driver Bus 1"]),
            ["Launchkey"]
        )
    }

    func testPatternMatchingOnlyIgnoredDevicesCountsAsUnmatched() {
        let selection = selection(inputs: ["DAW"], ignore: ["DAW"])
        XCTAssertEqual(selection.unmatchedInputPatterns(among: ["Minilab37 DAW"]), ["DAW"])
    }

    func testUnmatchedPatternsInDefaultAllModeIsEmpty() {
        let selection = selection(inputs: nil)
        XCTAssertEqual(selection.unmatchedInputPatterns(among: []), [])
    }

    func testUnmatchedOutputPatterns() {
        let selection = selection(outputs: ["Synth"])
        XCTAssertEqual(selection.unmatchedOutputPatterns(among: ["Minilab37 MIDI"]), ["Synth"])
    }
}
