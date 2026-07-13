import XCTest
@testable import MidimendCore

/// The `hardware` spec matching rule: case-insensitive substring. This is
/// the contract users rely on when writing configs, so pin it down.
final class DeviceMatchingTests: XCTestCase {

    func testExactNameMatches() {
        XCTAssertTrue(midiNameMatches("Minilab37 MIDI", pattern: "Minilab37 MIDI"))
    }

    func testSubstringMatches() {
        XCTAssertTrue(midiNameMatches("Minilab37 MIDI", pattern: "Minilab"))
        XCTAssertTrue(midiNameMatches("Minilab37 MIDI", pattern: "37 MIDI"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(midiNameMatches("Minilab37 MIDI", pattern: "MiniLab37 midi"))
        XCTAssertTrue(midiNameMatches("IAC Driver Bus 1", pattern: "iac"))
    }

    func testNonSubstringDoesNotMatch() {
        XCTAssertFalse(midiNameMatches("Minilab37 MIDI", pattern: "Launchkey"))
        XCTAssertFalse(midiNameMatches("Minilab37 MIDI", pattern: "Minilab 37"))
    }

    func testEmptyNameDoesNotMatch() {
        XCTAssertFalse(midiNameMatches("", pattern: "Minilab"))
    }
}
