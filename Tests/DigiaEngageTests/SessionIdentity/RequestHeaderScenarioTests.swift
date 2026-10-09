import XCTest

@testable import DigiaEngage

/// Scenarios doc §3.10: session and identity on outgoing requests. The client reads the session
/// and the request headers through `CurrentSessionRef`, as `SDKInstance.shared` wires it.
final class RequestHeaderScenarioTests: XCTestCase {

    private let ref = CurrentSessionRef()
    private lazy var client = URLSessionNetworkClient(
        sessionIdProvider: { [ref] in ref.sessionId },
        headerProvider: { [ref] in ref.requestHeaders }
    )

    private func publish(_ h: SessionIdentityHarness) {
        ref.set(h.session, identity: h.identity, requestHeaders: SDKRequestHeaders.make(config: DigiaConfig(apiKey: "key"), deviceId: h.identity.deviceId))
    }

    private func header(_ name: String, in callSite: [String: String] = [:]) -> String? {
        client.assembleHeaders(for: callSite).first { $0.key.lowercased() == name.lowercased() }?.value
    }

    func test_S47_everyRequestCarriesTheSessionIdReadWhenItIsSent() {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        publish(h)
        let s1 = h.session.sessionId
        XCTAssertEqual(header("X-Digia-Session-Id"), s1)

        h.clock.set(10, 5)
        h.identity.setUserId("asha")
        let s2 = h.session.sessionId
        XCTAssertNotEqual(s2, s1)
        XCTAssertEqual(header("X-Digia-Session-Id"), s2, "the very next request, including an S1 analytics batch")
    }

    // S48 (iOS X-Digia-User-Id, plan §5.2): every request carries the user ID while a user is set.
    func test_S48_everyRequestCarriesTheDeviceIdAndTheUserIdOnlyWhileAUserIsSet() {
        let h = SessionIdentityHarness(clock: TestClock(10, 0), deviceId: "D1")
        publish(h)
        XCTAssertEqual(header("X-Digia-Device-Id"), "D1")
        XCTAssertNil(header("X-Digia-User-Id"))

        h.identity.setUserId("asha")
        XCTAssertEqual(header("X-Digia-Device-Id"), "D1")
        XCTAssertEqual(header("X-Digia-User-Id"), "asha")

        h.identity.clearUserId()
        XCTAssertEqual(header("X-Digia-Device-Id"), "D1")
        XCTAssertNil(header("X-Digia-User-Id"))
    }

    func test_S49_aRequestBeforeInitializeCarriesNoEmptySessionOrDeviceHeader() {
        XCTAssertNil(header("X-Digia-Session-Id"))
        XCTAssertNil(header("X-Digia-Device-Id"))
    }

    // S50 as coded, pending decision: scenarios doc §6 item 8 (which session header wins).
    // On iOS the SDK's value overwrites the call site's.
    func test_S50_asCoded_theSdkSessionIdOverwritesACallSiteSessionHeader() {
        let h = SessionIdentityHarness(clock: TestClock(10, 0))
        publish(h)
        XCTAssertEqual(header("X-Digia-Session-Id", in: ["X-Digia-Session-Id": "caller"]), h.session.sessionId)
    }
}
