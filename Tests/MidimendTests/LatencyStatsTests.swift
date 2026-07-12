import XCTest
@testable import Midimend

/// The aggregation behind --measure: collects per-event latency samples
/// (nanoseconds) and renders a percentile summary. "queue" is driver receipt
/// → script entry (the dispatch hop), "total" is driver receipt → handling
/// done (sends issued).
final class LatencyStatsTests: XCTestCase {

    func testEmptyStatsProduceNoSummary() {
        var stats = LatencyStats()
        XCTAssertNil(stats.summarizeAndReset())
    }

    func testSummaryReportsCountPercentilesAndMax() {
        var stats = LatencyStats()
        for i in 1...4 {
            stats.record(hopNanos: UInt64(i) * 1_000, totalNanos: UInt64(i) * 10_000)
        }
        XCTAssertEqual(
            stats.summarizeAndReset(),
            "latency over 4 events — queue p50 2µs p99 4µs max 4µs; total p50 20µs p99 40µs max 40µs"
        )
    }

    func testMillisecondValuesUseMillisecondUnit() {
        var stats = LatencyStats()
        stats.record(hopNanos: 500_000, totalNanos: 1_234_000)
        XCTAssertEqual(
            stats.summarizeAndReset(),
            "latency over 1 event — queue p50 500µs p99 500µs max 500µs; total p50 1.2ms p99 1.2ms max 1.2ms"
        )
    }

    func testRecordingOrderDoesNotAffectPercentiles() {
        var stats = LatencyStats()
        for nanos in [40_000, 10_000, 30_000, 20_000] as [UInt64] {
            stats.record(hopNanos: nanos, totalNanos: nanos)
        }
        XCTAssertEqual(
            stats.summarizeAndReset(),
            "latency over 4 events — queue p50 20µs p99 40µs max 40µs; total p50 20µs p99 40µs max 40µs"
        )
    }

    func testSummarizeResetsForTheNextWindow() {
        var stats = LatencyStats()
        stats.record(hopNanos: 1_000, totalNanos: 2_000)
        _ = stats.summarizeAndReset()
        XCTAssertNil(stats.summarizeAndReset())
    }
}
