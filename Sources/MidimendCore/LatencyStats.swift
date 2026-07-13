import Foundation

/// Latency sample aggregation for --measure: per-event nanosecond samples in,
/// a one-line percentile summary out. "queue" is driver receipt → script
/// entry (the dispatch hop onto the JS queue), "total" is driver receipt →
/// handling done (any resulting sends issued).
///
/// Not internally synchronized: record and summarize on one queue.
struct LatencyStats {
    private var hopNanos: [UInt64] = []
    private var totalNanos: [UInt64] = []

    mutating func record(hopNanos hop: UInt64, totalNanos total: UInt64) {
        hopNanos.append(hop)
        totalNanos.append(total)
    }

    /// Renders the window collected so far and starts a fresh one.
    /// Returns nil when no events were recorded.
    mutating func summarizeAndReset() -> String? {
        guard !totalNanos.isEmpty else { return nil }
        defer {
            hopNanos.removeAll(keepingCapacity: true)
            totalNanos.removeAll(keepingCapacity: true)
        }
        let count = totalNanos.count
        let events = count == 1 ? "1 event" : "\(count) events"
        return "latency over \(events) — queue \(Self.percentiles(hopNanos));"
            + " total \(Self.percentiles(totalNanos))"
    }

    private static func percentiles(_ samples: [UInt64]) -> String {
        let sorted = samples.sorted()
        let p50 = format(nanos: nearestRank(0.5, of: sorted))
        let p99 = format(nanos: nearestRank(0.99, of: sorted))
        let max = format(nanos: sorted[sorted.count - 1])
        return "p50 \(p50) p99 \(p99) max \(max)"
    }

    private static func nearestRank(_ quantile: Double, of sorted: [UInt64]) -> UInt64 {
        let rank = Int((quantile * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static func format(nanos: UInt64) -> String {
        if nanos < 1_000_000 {
            return "\(Int((Double(nanos) / 1_000).rounded()))µs"
        }
        return String(format: "%.1fms", Double(nanos) / 1_000_000)
    }
}
