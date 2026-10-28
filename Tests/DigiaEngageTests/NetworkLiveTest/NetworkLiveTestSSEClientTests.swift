import Foundation
import Testing
@testable import DigiaEngage

/// `LiveTestSSEClient` is the only thing keeping a device visible to the dashboard, and it runs
/// unattended: nobody notices a dead stream until a PM presses "Test on device" and nothing
/// happens. These tests pin the decisions that keep it alive (when to reconnect, how long to
/// wait, when to give up) and the ones that keep it honest (a stale connection must not speak for
/// the current one).
///
/// Driven through `start()`/`stop()` and the handler the transport was given
/// (`NetworkLiveTestTransport`). iOS has no injectable clock here: the reconnect sleeps for real,
/// so timing is asserted once against the first backoff step (1 s + up to 0.5 s jitter) and the
/// schedule itself through `reconnectDelayMs`.
///
/// Port of `flutter/core/test/live_test_sse_client_test.dart` and the live-client half of
/// `flutter/core/test/network/sse_stream_test.dart`.
@Suite("Live test: SSE client", .serialized, .tags(.unit, .debug, .network))
@MainActor
struct NetworkLiveTestSSEClientTests {

    private final class Harness {
        let net = NetworkLiveTestTransport()
        var states: [LiveTestConnectionState] = []
        var events: [LiveTestSseEvent] = []
        var deviceName: String?
        private(set) var client: LiveTestSSEClient!

        @MainActor init(deviceName: String? = nil) {
            self.deviceName = deviceName
            client = LiveTestSSEClient(
                deviceName: { [unowned self] in self.deviceName },
                onEvent: { [unowned self] in self.events.append($0) },
                onConnectionStateChanged: { [unowned self] in self.states.append($0) },
                networkClient: net
            )
        }
    }

    private func started(deviceName: String? = nil) -> Harness {
        let h = Harness(deviceName: deviceName)
        h.client.start()
        return h
    }

    /// The first backoff step is 1 s plus up to 500 ms of jitter: nothing before 1 s, one
    /// reconnect by 1.5 s (with slack for a loaded simulator).
    private func expectReconnectAfterOneSecond(_ h: Harness, sourceLocation: SourceLocation = #_sourceLocation) async {
        let before = h.net.connects
        try? await Task.sleep(nanoseconds: 900_000_000)
        #expect(h.net.connects == before, "reconnected before 1 s", sourceLocation: sourceLocation)
        let reconnected = await networkLiveTestWait(timeout: 1.5) { h.net.connects == before + 1 }
        #expect(reconnected, "no reconnect within 1 s + jitter", sourceLocation: sourceLocation)
    }

    // MARK: - Reconnect backoff

    @Test("the backoff doubles from 1 s and caps at 30 s, plus the jitter")
    func backoffSchedule() {
        // Fails if: reconnectDelayMs changes its base, doubling, cap, or stops adding the jitter.
        #expect((0...7).map { reconnectDelayMs(attempt: $0, jitterMs: 0) }
            == [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000])
        #expect(reconnectDelayMs(attempt: 0, jitterMs: 499) == 1499)
        // A huge attempt count must not overflow the shift.
        #expect(reconnectDelayMs(attempt: 1_000, jitterMs: 0) == 30000)
        #expect(reconnectDelayMs(attempt: -1, jitterMs: 0) == 1000)
    }

    @Test("a dropped stream reports an error and reconnects after the first backoff step")
    func droppedStreamReconnects() async {
        let h = started()
        defer { h.client.stop() }

        h.net.handler.onError(URLError(.networkConnectionLost))

        // Fails if: LiveTestSSEClient.handleDisconnect stops calling scheduleReconnect, or
        // scheduleReconnect sleeps less than reconnectDelayMs.
        #expect(await networkLiveTestWait { h.states.last == .error })
        await expectReconnectAfterOneSecond(h)
        #expect(h.states.suffix(2) == [.error, .connecting])
    }

    @Test("a clean close reconnects too")
    func cleanCloseReconnects() async {
        let h = started()
        defer { h.client.stop() }

        h.net.handler.onClosed()

        // Fails if: the handler's onClosed stops routing to handleDisconnect — a server that
        // ends the stream (deploy, lease rotation) would leave the device dark until relaunch.
        #expect(await networkLiveTestWait { h.states.last == .error })
        #expect(await networkLiveTestWait(timeout: 2) { h.net.connects == 2 })
    }

    @Test("a confirmed connection resets the backoff; a growing one does not reset itself")
    func connectedResetsBackoff() async {
        let h = started()
        defer { h.client.stop() }

        h.net.handler.onError(URLError(.networkConnectionLost))
        #expect(await networkLiveTestWait(timeout: 2) { h.net.connects == 2 })
        // Second drop in a row: the 2 s step, so still nothing at 1.6 s.
        h.net.handler.onError(URLError(.networkConnectionLost))
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        // Fails if: scheduleReconnect stops incrementing reconnectAttempt.
        #expect(h.net.connects == 2, "the second consecutive drop must wait the 2 s step")
        #expect(await networkLiveTestWait(timeout: 1.5) { h.net.connects == 3 })

        // The server says hello: the next drop is a fresh problem, not the third in a row.
        h.net.send("connected", #"{"sdkConnectionId":"c1","deviceId":"d1"}"#)
        #expect(await networkLiveTestWait { h.states.last == .connected })
        h.net.handler.onError(URLError(.networkConnectionLost))
        // Fails if: dispatch's `connected` case stops resetting reconnectAttempt.
        #expect(await networkLiveTestWait(timeout: 1.7) { h.net.connects == 4 })
    }

    /// Known gap: iOS resets the backoff in the stream handler's `onOpen`
    /// (`LiveTestSSEClient.connect`, `onOpen: { self?.reconnectAttempt = 0 }`). Flutter resets only
    /// on the server's `connected` event: opening the HTTP stream is not proof the server
    /// accepted us, so a server that accepts the socket and then drops it is retried every
    /// second forever instead of backing off.
    @Test("a connection that opens but never confirms keeps backing off")
    func openAloneDoesNotResetBackoff() async {
        let h = started()
        defer { h.client.stop() }

        h.net.handler.onError(URLError(.networkConnectionLost))
        #expect(await networkLiveTestWait(timeout: 2) { h.net.connects == 2 })
        h.net.handler.onOpen()
        await networkLiveTestDrain()
        h.net.handler.onError(URLError(.networkConnectionLost))
        try? await Task.sleep(nanoseconds: 1_600_000_000)

        withKnownIssue("iOS resets the reconnect backoff on onOpen, Flutter only on `connected`") {
            #expect(h.net.connects == 2, "an unconfirmed open must not reset the 2 s step")
        }
    }

    @Test("a server `error` event is reported, then reconnects")
    func serverErrorEvent() async {
        let h = started()
        defer { h.client.stop() }

        h.net.send("error", #"{"message":"bad device id"}"#)

        #expect(await networkLiveTestWait { h.states.last == .error })
        guard case .streamError(let message) = h.events.last else {
            Issue.record("no stream error reported: \(h.events)")
            return
        }
        // Fails if: dispatch's `error` case drops the server's message or stops calling
        // handleDisconnect.
        #expect(message == "bad device id")
        #expect(await networkLiveTestWait(timeout: 2) { h.net.connects == 2 })
    }

    @Test("a server `error` event without a message still reports one")
    func serverErrorEventWithoutMessage() async {
        let h = started()
        defer { h.client.stop() }

        h.net.send("error", "")

        #expect(await networkLiveTestWait { !h.events.isEmpty })
        guard case .streamError(let message) = h.events.last else {
            Issue.record("no stream error reported: \(h.events)")
            return
        }
        // Fails if: the fallback for an empty/missing message is removed — the debug overlay
        // would show a blank reason.
        #expect(message == "live test stream error")
    }

    // MARK: - A rejected key

    @Test("HTTP 401/403 stops the loop for good; start() is the way back in", arguments: [401, 403])
    func rejectedKeyStops(status: Int) async {
        let h = started()
        defer { h.client.stop() }

        h.net.handler.onError(SseHTTPStatusError(statusCode: status))

        #expect(await networkLiveTestWait { !h.client.isRunning })
        #expect(h.states.last == .error)
        // Longer than the first backoff step plus its jitter.
        try? await Task.sleep(nanoseconds: 1_700_000_000)
        // Fails if: the 401/403 branch in connect's onError falls through to handleDisconnect —
        // retrying cannot fix a refused key, and every retry is a request the backend refuses.
        #expect(h.net.connects == 1, "retrying cannot fix a refused key")

        h.client.start()
        #expect(h.net.connects == 2)
    }

    @Test("HTTP 500 is a hiccup, not a verdict")
    func serverErrorReconnects() async {
        let h = started()
        defer { h.client.stop() }

        h.net.handler.onError(SseHTTPStatusError(statusCode: 500))

        #expect(await networkLiveTestWait { h.states.last == .error })
        // Fails if: the auth branch widens to all 4xx/5xx.
        #expect(h.client.isRunning)
        #expect(await networkLiveTestWait(timeout: 2) { h.net.connects == 2 })
    }

    // MARK: - A superseded connection

    /// Known gap: iOS's stream handler has no connection generation. A late callback from a
    /// stream the client already replaced goes straight to `handleDisconnect`
    /// (`LiveTestSSEClient.connect`, the handler's `onError`/`onClosed`/`onEvent` closures), which
    /// cancels the *current* subscription, reports `.error` and schedules a reconnect. Flutter
    /// drops callbacks whose generation is not the live one.
    @Test("a stale connection cannot report state or schedule a reconnect after a restart")
    func staleConnectionIsIgnored() async {
        let h = started()
        defer { h.client.stop() }
        let stale = h.net.handler

        h.client.stop()
        h.client.start()
        #expect(h.net.connects == 2)
        let statesBefore = h.states

        // The old socket finally dies. The client is running again, so only a generation would
        // tell this callback it is no longer the live one.
        stale.onError(URLError(.networkConnectionLost))
        stale.onClosed()
        stale.onEvent(SseEvent(event: "connected", data: "{}"))
        await networkLiveTestDrain(0.1)

        withKnownIssue("iOS LiveTestSSEClient has no connection generation; a stale stream drives the live one") {
            #expect(h.states == statesBefore)
            #expect(h.events.isEmpty)
            #expect(h.net.openStreams == 1)
        }
    }

    @Test("stop() during a backoff wait prevents the reconnect")
    func stopDuringBackoff() async {
        let h = started()

        h.net.handler.onError(URLError(.networkConnectionLost))
        #expect(await networkLiveTestWait { h.states.last == .error })
        h.client.stop()

        try? await Task.sleep(nanoseconds: 1_700_000_000)
        // Fails if: stop() stops cancelling reconnectTask, or the reconnect Task skips its
        // `!self.stopped` check — a backgrounded or switched-off device would reconnect.
        #expect(h.net.connects == 1)
        #expect(h.states.last == .disconnected)
        #expect(h.net.openStreams == 0)
    }

    @Test("start() is idempotent while running")
    func startIsIdempotent() {
        let h = started()
        defer { h.client.stop() }

        h.client.start()
        h.client.start()

        // Fails if: start() loses its `guard stopped` — two streams would deliver every test twice.
        #expect(h.net.connects == 1)
        #expect(h.states == [.connecting])
    }

    // MARK: - Event dispatch

    @Test("`connected` carries the ids and marks the stream live")
    func connectedEvent() async {
        let h = started()
        defer { h.client.stop() }

        h.net.send("connected", #"{"sdkConnectionId":"c1","deviceId":"d1"}"#)

        #expect(await networkLiveTestWait { !h.events.isEmpty })
        guard case .connected(let connectionId, let deviceId) = h.events.onlyElement else {
            Issue.record("expected one connected event: \(h.events)")
            return
        }
        #expect(connectionId == "c1")
        #expect(deviceId == "d1")
        #expect(h.states == [.connecting, .connected])
    }

    @Test("`campaign_test` delivers the campaign and variables")
    func campaignTestEvent() async throws {
        let h = started()
        defer { h.client.stop() }

        h.net.send("campaign_test", #"""
            {"testInvocationId":"inv-1","campaignId":"camp-1","campaign":{"campaignKey":"k"},"variables":{"name":"Asha","count":3}}
            """#)

        #expect(await networkLiveTestWait { !h.events.isEmpty })
        let invocation = try #require(h.events.onlyElement?.invocation)
        #expect(invocation.testInvocationId == "inv-1")
        #expect(invocation.campaignId == "camp-1")
        #expect(invocation.campaign?["campaignKey"] as? String == "k")
        #expect(invocation.variables["name"] as? String == "Asha")
        #expect(invocation.variables["count"] as? Int == 3)
    }

    @Test("a campaign that is not an object arrives as nil, and non-object variables as empty")
    func campaignTestWrongShapes() async throws {
        // The handler turns nil into `malformedCampaignSkipped`. A string or list here must not be
        // force-cast into a dictionary inside the stream.
        let h = started()
        defer { h.client.stop() }

        h.net.send("campaign_test", #"{"testInvocationId":"inv-1","campaignId":"camp-1","campaign":"oops","variables":[1,2]}"#)

        #expect(await networkLiveTestWait { !h.events.isEmpty })
        let invocation = try #require(h.events.onlyElement?.invocation)
        #expect(invocation.testInvocationId == "inv-1")
        #expect(invocation.campaign == nil)
        #expect(invocation.variables.isEmpty)
    }

    @Test("a malformed frame does not kill the stream")
    func malformedFrameIsSurvived() async {
        let h = started()
        defer { h.client.stop() }

        h.net.send("campaign_test", "{not json")
        h.net.send("campaign_test", #"{"testInvocationId":"inv-2","campaignId":"c","campaign":{}}"#)

        #expect(await networkLiveTestWait { h.events.count == 2 })
        #expect(h.client.isRunning)
        #expect(h.states == [.connecting])
        #expect(h.events.compactMap(\.invocation).map(\.testInvocationId).contains("inv-2"))
        // A bad frame is not a disconnect.
        try? await Task.sleep(nanoseconds: 1_600_000_000)
        #expect(h.net.connects == 1)
    }

    @Test("an unknown event type is ignored")
    func unknownEventIgnored() async {
        let h = started()
        defer { h.client.stop() }

        h.net.send("some_future_event", #"{"a":1}"#)
        await networkLiveTestDrain()

        // Fails if: dispatch's `default` case disconnects — a server that adds an event type
        // would knock every shipped SDK offline.
        #expect(h.events.isEmpty)
        #expect(h.states == [.connecting])
        #expect(h.client.isRunning)
    }

    // MARK: - The connect request

    @Test("is a debug-environment POST to the connect endpoint with the device name")
    func connectRequest() throws {
        let h = started(deviceName: "Asha's Pixel")
        defer { h.client.stop() }

        let request = try #require(h.net.recordedRequests.onlyElement)
        #expect(request.method == .post)
        #expect(request.url.path == "/api/v1/engage/sdk/live/connect")
        // Fails if: connect stops sending X-Digia-Environment: debug — the backend files the
        // device under production and the dashboard never lists it.
        #expect(request.headers["X-Digia-Environment"] == "debug")
        #expect(h.net.lastConnectBody == ["deviceName": "Asha's Pixel"])
        #expect(request.readTimeout == 45)
    }

    @Test("omits deviceName when none is set")
    func connectRequestWithoutName() throws {
        let h = started()
        defer { h.client.stop() }

        #expect(h.net.lastConnectBody == [:])
    }

    @Test("reads the device name afresh on every reconnect")
    func deviceNameReadPerConnect() async {
        // Presence metadata is captured when the stream opens; a rename takes effect only
        // because each connect asks again.
        let h = started()
        defer { h.client.stop() }

        h.deviceName = "Renamed"
        h.net.handler.onError(URLError(.networkConnectionLost))
        #expect(await networkLiveTestWait(timeout: 2) { h.net.connects == 2 })

        #expect(h.net.lastConnectBody == ["deviceName": "Renamed"])
    }
}

private extension Array {
    var onlyElement: Element? { count == 1 ? first : nil }
}

private extension LiveTestSseEvent {
    var invocation: LiveTestInvocation? {
        if case .campaignTest(let invocation) = self { return invocation }
        return nil
    }
}
