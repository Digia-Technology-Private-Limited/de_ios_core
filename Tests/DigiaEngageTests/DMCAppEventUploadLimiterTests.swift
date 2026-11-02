import Testing
@testable import DigiaEngage

/// Flutter: `test/analytics/app_event_upload_limiter_test.dart`.
@MainActor
@Suite("AppEventUploadLimiter")
struct DMCAppEventUploadLimiterTests {
    private final class Clock { var now: Int64 = 1000 }

    private func make(
        enabled: Bool = true,
        ratePerMinute: Int = 0,
        burst: Int = 0,
        blockedNames: Set<String> = []
    ) -> (AppEventUploadLimiter, Clock, () -> Void) {
        let clock = Clock()
        let limiter = AppEventUploadLimiter(nowMs: { clock.now })
        let apply = {
            limiter.applyPolicy(AppEventUploadPolicy(
                enabled: enabled, ratePerMinute: ratePerMinute, burst: burst, blockedNames: blockedNames
            ))
        }
        apply()
        return (limiter, clock, apply)
    }

    @Test("a rate of 0 is unlimited")
    func unlimited() {
        let (limiter, _, _) = make()
        for _ in 0..<1000 { #expect(limiter.consume("add_to_cart") == nil) }
    }

    @Test("bursts, then sustains the per-minute rate")
    func burstThenSustain() {
        // 60 a minute is one token a second, with three in hand.
        let (limiter, clock, _) = make(ratePerMinute: 60, burst: 3)

        #expect(limiter.consume("e") == nil)
        #expect(limiter.consume("e") == nil)
        #expect(limiter.consume("e") == nil)
        #expect(limiter.consume("e") == .rate)

        clock.now += 1000  // one second refills exactly one token
        #expect(limiter.consume("e") == nil)

        clock.now += 500  // half a token is not a token
        #expect(limiter.consume("e") == .rate)
        clock.now += 500
        #expect(limiter.consume("e") == nil)
    }

    @Test("no named burst means one minute of capacity")
    func noBurstIsAMinute() {
        let (limiter, _, _) = make(ratePerMinute: 2, burst: 0)
        #expect(limiter.consume("e") == nil)
        #expect(limiter.consume("e") == nil)
        #expect(limiter.consume("e") == .rate)
    }

    @Test("refill never exceeds the burst")
    func refillClampsToBurst() {
        let (limiter, clock, _) = make(ratePerMinute: 60, burst: 2)
        clock.now += 60_000  // a minute of refill, clamped to the two-token burst
        #expect(limiter.consume("e") == nil)
        #expect(limiter.consume("e") == nil)
        #expect(limiter.consume("e") == .rate)
    }

    @Test("the upload switch drops everything as disabled")
    func uploadSwitch() {
        let (limiter, _, _) = make(enabled: false)
        #expect(limiter.consume("e") == .disabled)
        #expect(limiter.consume("e") == .disabled)
    }

    @Test("the blocklist drops by name, before the rate")
    func blocklistBeforeRate() {
        let (limiter, _, _) = make(ratePerMinute: 1, burst: 1, blockedNames: ["scroll"])
        #expect(limiter.consume("scroll") == .blocked)
        #expect(limiter.consume("scroll") == .blocked)
        #expect(limiter.consume("product_viewed") == nil)
        #expect(limiter.consume("product_viewed") == .rate)
    }

    @Test("applying a policy refills the bucket")
    func applyRefills() {
        let (limiter, _, apply) = make(ratePerMinute: 1, burst: 1)
        #expect(limiter.consume("e") == nil)
        #expect(limiter.consume("e") == .rate)
        apply()
        #expect(limiter.consume("e") == nil)
    }
}
