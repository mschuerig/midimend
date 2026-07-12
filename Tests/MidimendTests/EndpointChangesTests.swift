import XCTest
@testable import Midimend

/// The plug/unplug log lines derived from comparing the previous and current
/// sets of present hardware-endpoint names.
final class EndpointChangesTests: XCTestCase {

    func testAppearedAndDisappearedAcrossSourcesAndDestinations() {
        let lines = EndpointChanges.messages(
            previousSources: ["Minilab37 MIDI"],
            currentSources: ["Minilab37 MIDI", "Minilab37 DAW"],
            previousDestinations: ["Old Synth"],
            currentDestinations: []
        )
        XCTAssertEqual(lines, [
            "MIDI input appeared: Minilab37 DAW",
            "MIDI output disappeared: Old Synth",
        ])
    }

    func testNoChangeProducesNoLines() {
        let lines = EndpointChanges.messages(
            previousSources: ["A"], currentSources: ["A"],
            previousDestinations: ["B"], currentDestinations: ["B"]
        )
        XCTAssertTrue(lines.isEmpty)
    }

    func testAppearancesAreSortedForStableOutput() {
        let lines = EndpointChanges.messages(
            previousSources: [], currentSources: ["Zeta", "Alpha"],
            previousDestinations: [], currentDestinations: []
        )
        XCTAssertEqual(lines, [
            "MIDI input appeared: Alpha",
            "MIDI input appeared: Zeta",
        ])
    }
}
