import Testing
@testable import DigiaEngage

/// `LiveTestSSEClient` itself wraps `URLSession.bytes(for:)` — SSE framing is
/// handled by `AsyncLineSequence`, not custom code here, so there's no frame
/// parser of our own to unit test. The one piece of custom logic worth
/// covering in isolation is the reconnect backoff sequence, pulled out as a
/// pure function specifically so it's testable without touching URLSession or
/// Tasks. End-to-end stream behavior is covered by the manual verification
/// pass against a real backend (see the implementation plan).
@Suite("reconnectDelayMs")
struct ReconnectDelayMsTests {
    @Test("backoff doubles each attempt starting at 1 second")
    func backoffDoubles() {
        #expect(reconnectDelayMs(attempt: 0, jitterMs: 0) == 1000)
        #expect(reconnectDelayMs(attempt: 1, jitterMs: 0) == 2000)
        #expect(reconnectDelayMs(attempt: 2, jitterMs: 0) == 4000)
        #expect(reconnectDelayMs(attempt: 3, jitterMs: 0) == 8000)
        #expect(reconnectDelayMs(attempt: 4, jitterMs: 0) == 16000)
    }

    @Test("backoff caps at 30 seconds and does not keep growing")
    func backoffCaps() {
        #expect(reconnectDelayMs(attempt: 5, jitterMs: 0) == 30000)
        #expect(reconnectDelayMs(attempt: 20, jitterMs: 0) == 30000)
    }

    @Test("jitter is added on top of the base delay")
    func jitterAdded() {
        #expect(reconnectDelayMs(attempt: 0, jitterMs: 500) == 1500)
        #expect(reconnectDelayMs(attempt: 10, jitterMs: 500) == 30500)
    }
}
