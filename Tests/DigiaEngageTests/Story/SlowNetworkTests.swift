import Foundation
import Testing

@testable import DigiaEngage

// The one slow rule (S9): slow = metered OR the last measured warm below 1500 kbps; an unknown
// signal votes nothing. iOS has no link-rate API, so there is no third vote. Mirrors Android
// `SlowNetwork` / `SlowNetworkThroughput`.

@Suite("Slow network", .tags(.media, .unit, .inline))
struct SlowNetworkTests {
    // Fails if the threshold moves or flips direction: the `measuredKbps < slowDownstreamKbps`
    // comparison in `slowNetworkFor`.
    @Test("a measured warm below 1500 kbps is slow, 1500 is not")
    func measuredThroughputBoundary() {
        #expect(slowNetworkFor(isExpensive: false, isConstrained: false, measuredKbps: 1_499.9))
        #expect(!slowNetworkFor(isExpensive: false, isConstrained: false, measuredKbps: 1_500))
        #expect(!slowNetworkFor(isExpensive: false, isConstrained: false, measuredKbps: 9_000))
    }

    // Fails if an unknown signal votes: the `if let measuredKbps` guard (a nil or non-finite
    // sample must leave the full window planned, as on a cold start).
    @Test("an unknown or unusable measurement votes nothing")
    func unknownVotesNothing() {
        #expect(!slowNetworkFor(isExpensive: false, isConstrained: false, measuredKbps: nil))
        #expect(!slowNetworkFor(isExpensive: false, isConstrained: false, measuredKbps: .nan))
        #expect(!slowNetworkFor(isExpensive: false, isConstrained: false, measuredKbps: -5))
    }

    // Fails if a metered path stops voting slow: the `isExpensive || isConstrained` line.
    @Test("a metered path is slow whatever was measured")
    func meteredIsSlow() {
        #expect(slowNetworkFor(isExpensive: true, isConstrained: false, measuredKbps: 50_000))
        #expect(slowNetworkFor(isExpensive: false, isConstrained: true, measuredKbps: nil))
    }

    // Fails if the rate is computed in the wrong unit: the `* 8 / 1_000 / elapsed` in `note`
    // (512 KiB in 2 s is 2097.152 kbps).
    @Test("a warm's throughput is kilobits per second")
    func throughputUnit() {
        let throughput = SlowNetworkThroughput()
        throughput.note(bytes: 512 * 1_024, elapsed: 2)

        #expect(abs((throughput.lastKbps ?? 0) - 2_097.152) < 0.001)
    }

    // Fails if a cache hit overwrites a real sample: the `elapsed >= minimumElapsed` guard in
    // `note` (a warm served from disk returns at once and would read as a fast link, clearing
    // a real slow verdict). Empty warms (a cancelled or failed one answers 0 bytes) vote nothing.
    @Test("a warm served from the cache, or an empty one, is not a measurement")
    func cacheHitsAndEmptyWarmsAreDiscarded() {
        let throughput = SlowNetworkThroughput()
        throughput.note(bytes: 512 * 1_024, elapsed: 10)       // 419 kbps: slow
        throughput.note(bytes: 512 * 1_024, elapsed: 0.001)    // from the cache
        throughput.note(bytes: 0, elapsed: 5)                  // cancelled

        #expect(abs((throughput.lastKbps ?? 0) - 419.4304) < 0.001)
    }

    // Fails if the source ignores measurements: the `noteWarm` forward to the throughput
    // (the verdict would stay "not slow" however slow the warms are).
    @Test("a slow warm makes the live source slow")
    func slowWarmMakesTheSourceSlow() {
        let source = PathSlowNetworkSource()
        source.noteWarm(bytes: 512 * 1_024, elapsed: 10)

        #expect(source.isSlow)
    }
}
