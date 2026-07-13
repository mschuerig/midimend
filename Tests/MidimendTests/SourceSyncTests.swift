import XCTest
@testable import Midimend

/// The connect/prune decisions MIDIIO executes on every setup-change: which
/// present sources to connect, and which remembered connections to forget.
final class SourceSyncTests: XCTestCase {

    private func present(_ id: Int32, _ name: String, matched: Bool = true) -> SourceSync.Present {
        SourceSync.Present(id: id, name: name, matched: matched)
    }

    func testConnectsMatchedNewSources() {
        let plan = SourceSync.plan(present: [present(1, "Minilab37 MIDI")], connected: [])
        XCTAssertEqual(plan.connect.map(\.id), [1])
        XCTAssertEqual(plan.retainedIDs, [])
    }

    func testAlreadyConnectedSourceIsNotReconnected() {
        // Repeated setup-change notifications must be idempotent.
        let plan = SourceSync.plan(present: [present(1, "Minilab37 MIDI")], connected: [1])
        XCTAssertTrue(plan.connect.isEmpty)
        XCTAssertEqual(plan.retainedIDs, [1])
    }

    func testUnmatchedSourceIsNotConnected() {
        let plan = SourceSync.plan(
            present: [present(2, "Minilab37 DAW", matched: false)],
            connected: []
        )
        XCTAssertTrue(plan.connect.isEmpty)
    }

    func testVanishedSourceIsForgottenSoAReplugReconnects() {
        // Unplug: id 1 is gone. Its remembered connection must be dropped —
        // CoreMIDI may reuse the same unique ID on replug, and a stale entry
        // would make the replug look already-connected against a severed
        // connection.
        let unplugged = SourceSync.plan(present: [], connected: [1])
        XCTAssertEqual(unplugged.retainedIDs, [])

        let replugged = SourceSync.plan(
            present: [present(1, "Minilab37 MIDI")],
            connected: unplugged.retainedIDs
        )
        XCTAssertEqual(replugged.connect.map(\.id), [1])
    }

    func testUnmatchedPresenceStillRetainsItsUnrelatedConnections() {
        // An ignored port being present must not disturb a matched one.
        let plan = SourceSync.plan(
            present: [present(1, "Minilab37 MIDI"), present(2, "Minilab37 DAW", matched: false)],
            connected: [1]
        )
        XCTAssertTrue(plan.connect.isEmpty)
        XCTAssertEqual(plan.retainedIDs, [1])
    }
}
