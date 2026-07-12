import XCTest
@testable import Midimend

/// The one-shot timer behind sendAfterMilliseconds: strict (no coalescing
/// leeway), fires on the target queue, not before the deadline.
final class StrictTimerTests: XCTestCase {

    func testFiresOnTheTargetQueueNotBeforeTheDeadline() {
        let queue = DispatchQueue(label: "test.strict")
        let fired = expectation(description: "timer fired")
        let start = DispatchTime.now()
        Engine.scheduleStrict(afterMilliseconds: 50, on: queue) {
            dispatchPrecondition(condition: .onQueue(queue))
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            XCTAssertGreaterThanOrEqual(elapsedMs, 49)
            fired.fulfill()
        }
        wait(for: [fired], timeout: 2)
    }

    func testFiresExactlyOnce() {
        let queue = DispatchQueue(label: "test.strict-once")
        let fired = expectation(description: "timer fired")
        fired.expectedFulfillmentCount = 1
        fired.assertForOverFulfill = true
        Engine.scheduleStrict(afterMilliseconds: 10, on: queue) {
            fired.fulfill()
        }
        // Give a repeating timer time to misfire again before we check.
        wait(for: [fired], timeout: 2)
        queue.sync { Thread.sleep(forTimeInterval: 0.05) }
    }
}
