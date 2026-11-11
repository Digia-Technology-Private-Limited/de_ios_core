import Foundation
import Testing

@testable import DigiaEngage

// The slow rule's pure edges (T8) that no surface reaches: exactly 1500 kbps is not slow (a real
// clock never lands on it), a NaN or negative rate votes nothing (`note` never produces one), and a
// metered path is slow (`NWPath` cannot be built). The measured side, the unit, the cache and failed
// warms, and the source's forward are proved through the viewer in `StoryPageTests`.

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
}
