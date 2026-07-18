import Foundation

/// Keeps the display awake while a human is actively playing, by declaring
/// user activity to the system on a throttled cadence — the same signal a
/// keystroke or mouse move produces, so it merely defers the screensaver and
/// display sleep for the user's configured timeout rather than pinning the
/// screen on forever.
///
/// Fed every inbound message via `noteEvent` and advanced by the engine's idle
/// timer via `tick`; both happen on the engine's serial queue, so the guard
/// holds no lock. Only channel-voice messages (status 0x80–0xEF: notes, CC,
/// pitch bend, program change, aftertouch — a person touching the controller)
/// count. System real-time/common traffic (0xF0–0xFF: Active Sensing, Timing
/// Clock, …), which a device emits on its own, must never hold the screen
/// awake. The I/O layer already withholds those from this path; keeping the
/// predicate here makes the guarantee local, self-contained, and testable.
final class WakeGuard {
    private let declareActivity: () -> Void
    private let throttleTicks: Int
    private var pending = false
    private var ticksSinceDeclaration: Int

    /// - Parameters:
    ///   - throttleTicks: minimum idle ticks between two activity declarations.
    ///     At the engine's 0.25 s tick, 40 ≈ once per 10 s while playing — far
    ///     below any screensaver timeout, and negligible as a system call.
    ///   - declareActivity: performs the actual "the user is active" call.
    init(throttleTicks: Int = 40, declareActivity: @escaping () -> Void) {
        self.throttleTicks = throttleTicks
        self.declareActivity = declareActivity
        // Prime the counter so the first qualifying event declares on the next
        // tick instead of waiting out a full window.
        self.ticksSinceDeclaration = throttleTicks
    }

    /// Records an inbound message. Only channel-voice status bytes count as a
    /// person playing; system messages are ignored.
    func noteEvent(status: UInt8) {
        guard status >= 0x80, status < 0xF0 else { return }
        pending = true
    }

    /// Advances one engine idle tick, declaring activity at most once per
    /// throttle window and only if a qualifying event arrived since the last
    /// declaration. When play stops, `pending` stays false and the display is
    /// left to sleep on its own schedule.
    func tick() {
        ticksSinceDeclaration += 1
        guard pending, ticksSinceDeclaration >= throttleTicks else { return }
        declareActivity()
        ticksSinceDeclaration = 0
        pending = false
    }
}
