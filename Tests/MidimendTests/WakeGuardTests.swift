import XCTest
@testable import MidimendCore

/// WakeGuard's throttling and message-class filtering, exercised without any
/// IOKit: the "declare user activity" effect is an injected counter, and the
/// engine's idle tick is driven by hand.
final class WakeGuardTests: XCTestCase {

    /// Reference box so the escaping declare closure can record calls.
    private final class Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    private func makeGuard(throttleTicks: Int = 4) -> (WakeGuard, Counter) {
        let counter = Counter()
        let guardian = WakeGuard(throttleTicks: throttleTicks) { counter.bump() }
        return (guardian, counter)
    }

    /// A single channel-voice event should hold the display awake on the very
    /// next tick — no waiting out a full throttle window first.
    func testChannelVoiceEventDeclaresActivityOnNextTick() {
        let (guardian, counter) = makeGuard()
        guardian.noteEvent(status: 0x90) // Note On, channel 1
        guardian.tick()
        XCTAssertEqual(counter.count, 1)
    }

    /// Idle ticks with no traffic must never declare activity — that is what
    /// lets the Mac sleep normally when nobody is playing.
    func testTicksWithoutEventsNeverDeclare() {
        let (guardian, counter) = makeGuard()
        for _ in 0..<10 { guardian.tick() }
        XCTAssertEqual(counter.count, 0)
    }

    /// The whole reason the feature exists: the automatic streams a device
    /// emits on its own — Active Sensing (0xFE), Timing Clock (0xF8), Reset
    /// (0xFF) — must not count as a human playing.
    func testSystemMessagesDoNotCountAsActivity() {
        let (guardian, counter) = makeGuard()
        for status: UInt8 in [0xF8, 0xFA, 0xFE, 0xFF] { guardian.noteEvent(status: status) }
        for _ in 0..<10 { guardian.tick() }
        XCTAssertEqual(counter.count, 0)
    }

    /// All channel-voice statuses (0x8n–0xEn) qualify: notes, CC, program
    /// change, pitch bend, aftertouch.
    func testEveryChannelVoiceStatusQualifies() {
        for status: UInt8 in [0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0x9F] {
            let (guardian, counter) = makeGuard()
            guardian.noteEvent(status: status)
            guardian.tick()
            XCTAssertEqual(counter.count, 1, "status \(String(status, radix: 16)) should qualify")
        }
    }

    /// While playing continuously, activity is declared at most once per
    /// throttle window, not on every tick.
    func testDeclarationsAreThrottledWhilePlaying() {
        let (guardian, counter) = makeGuard(throttleTicks: 4)
        // 12 ticks, an event before each — expect declarations at ticks 1, 5, 9.
        for _ in 0..<12 {
            guardian.noteEvent(status: 0xB0) // Control Change
            guardian.tick()
        }
        XCTAssertEqual(counter.count, 3)
    }

    /// When playing stops, declarations stop with it — no lingering hold on
    /// the display beyond the last activity's window.
    func testDeclarationsStopWhenActivityCeases() {
        let (guardian, counter) = makeGuard(throttleTicks: 4)
        guardian.noteEvent(status: 0x90)
        guardian.tick()
        XCTAssertEqual(counter.count, 1)
        for _ in 0..<20 { guardian.tick() } // silence
        XCTAssertEqual(counter.count, 1)
    }

    /// After a quiet spell the guard resumes on the next event, without owing
    /// any "catch-up" declarations from the silence.
    func testResumesAfterQuietPeriod() {
        let (guardian, counter) = makeGuard(throttleTicks: 4)
        guardian.noteEvent(status: 0x90)
        guardian.tick()
        for _ in 0..<20 { guardian.tick() }
        guardian.noteEvent(status: 0x90)
        guardian.tick()
        XCTAssertEqual(counter.count, 2)
    }
}
