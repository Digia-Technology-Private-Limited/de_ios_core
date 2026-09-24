import Foundation
import Testing

@testable import DigiaEngage

// MARK: - MockURLProtocol for URLSession Network Testing

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        requestHandler = handler
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        requestHandler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        MockURLProtocol.lock.lock()
        let handler = MockURLProtocol.requestHandler
        MockURLProtocol.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Test Suite

@Suite("NetworkClient and Contract Tests", .serialized)
struct NetworkClientTests {

    private func makeTestClient(
        headerProvider: (@Sendable () -> [String: String])? = nil
    ) -> URLSessionNetworkClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return URLSessionNetworkClient(session: session, headerProvider: headerProvider)
    }

    // MARK: - URLSessionNetworkClient Header Duplication & Contract Tests

    @Test("URLSessionNetworkClient sends each header once, with the platform tag")
    func urlSessionHeaderDuplication() async throws {
        let client = makeTestClient(headerProvider: {
            [
                "X-Digia-Project-Id": "proj_p1",
                "x-digia-device-id": "dev_d1",
            ]
        })

        var capturedRequest: URLRequest?
        MockURLProtocol.setHandler { req in
            capturedRequest = req
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (resp, Data(#"{"success":true}"#.utf8))
        }

        let request = NetworkRequest(
            url: URL(string: "https://api.digia.cloud/v1/events")!,
            method: .post,
            headers: ["X-Custom": "CustomVal"]
        )

        let response = try await client.execute(request: request)
        #expect(response.statusCode == 200)
        #expect(response.isSuccessful)

        // 1. One entry per header name, whatever casing the layers used (D7)
        let assembled = client.assembleHeaders(for: request.headers)
        let names = assembled.keys.map { $0.lowercased() }
        #expect(names.count == Set(names).count)
        #expect(assembled["X-Digia-Project-Id"] == "proj_p1")
        #expect(assembled["x-digia-device-id"] == "dev_d1")
        #expect(assembled["X-Digia-Platform"] == "ios")
        #expect(assembled["x-digia-sdk-version"] == DigiaSdkVersion.value)
        #expect(assembled["X-Digia-Version"] == DigiaSdkVersion.value)
        #expect(assembled["X-Custom"] == "CustomVal")

        // 2. Verify wire URLRequest delivers the headers
        let wireRequest = try #require(capturedRequest)
        #expect(wireRequest.value(forHTTPHeaderField: "X-Digia-Project-Id") == "proj_p1")
        #expect(wireRequest.value(forHTTPHeaderField: "X-Digia-Device-Id") == "dev_d1")
        #expect(wireRequest.value(forHTTPHeaderField: "X-Digia-Platform") == "ios")
        #expect(wireRequest.value(forHTTPHeaderField: "X-Custom") == "CustomVal")
    }

    @Test("request headers beat client defaults case-insensitively; legacy pairs are filled, never overwritten")
    func headerPrecedence() {
        let client = URLSessionNetworkClient(
            sessionIdProvider: { "sess-live" },
            headerProvider: { ["X-DIGIA-DEVICE-ID": "from-provider"] }
        )
        let assembled = client.assembleHeaders(for: [
            "X-Digia-Sdk-Version": "native/ios/9.9.9",
            "X-Digia-Environment": "debug",
            "X-Digia-Sdk-Environment": "production",
            "x-digia-device-id": "from-request",
            "x-digia-session-id": "stale",
            "x-digia-platform": "android",
        ])

        let names = assembled.keys.map { $0.lowercased() }
        #expect(names.count == Set(names).count)
        func value(_ name: String) -> String? {
            assembled.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        #expect(value("x-digia-sdk-version") == "native/ios/9.9.9")
        #expect(value("X-Digia-Version") == DigiaSdkVersion.value)
        #expect(value("X-Digia-Environment") == "debug")
        #expect(value("X-Digia-Sdk-Environment") == "production")
        #expect(value("X-Digia-Device-Id") == "from-request")
        #expect(value("X-Digia-Session-Id") == "sess-live")
        #expect(value("X-Digia-Platform") == "ios")

        let filled = client.assembleHeaders(for: ["X-Digia-Sdk-Environment": "sandbox"])
        #expect(filled["X-Digia-Environment"] == "sandbox")
    }

    @Test("URLSessionNetworkClient injects canonical session headers from sessionIdProvider")
    func urlSessionSessionIdProvider() {
        let client = URLSessionNetworkClient(
            sessionIdProvider: { "sess_test_123" }
        )
        let assembled = client.assembleHeaders(for: [:])
        #expect(assembled["X-Digia-Session-Id"] == "sess_test_123")
    }

    @Test("a request after a session rotation carries the new session ID")
    func sessionHeaderFollowsRotation() async throws {
        let storage = UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)
        let sessionManager = SessionManager(storage: storage.scoped("session"), observeLifecycle: false)
        let currentSession = CurrentSessionRef()
        currentSession.set(sessionManager)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = URLSessionNetworkClient(
            session: URLSession(configuration: config),
            sessionIdProvider: { currentSession.sessionId }
        )
        let captured = LockedBox<[String?]>([])
        MockURLProtocol.setHandler { req in
            captured.mutate { $0.append(req.value(forHTTPHeaderField: "X-Digia-Session-Id")) }
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.reset() }
        let request = NetworkRequest(url: URL(string: "https://api.digia.cloud/submission")!, method: .post)

        let before = sessionManager.sessionId
        _ = try await client.execute(request: request)
        sessionManager.reset()
        let after = sessionManager.sessionId
        _ = try await client.execute(request: request)

        #expect(before != after)
        #expect(captured.value == [before, after])
    }

    // MARK: - SSE stream ownership

    @Test("an SSE stream keeps its handler alive: events arrive with no outside reference to it")
    func sseStreamOwnsItsHandler() async throws {
        let client = makeTestClient()
        MockURLProtocol.setHandler { req in
            let resp = HTTPURLResponse(
                url: req.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (resp, Data("event: connected\ndata: {}\n\nevent: campaign_test\ndata: x\n\n".utf8))
        }
        defer { MockURLProtocol.reset() }

        let received = LockedBox<[String]>([])
        let subscription = LockedBox<(any CancellableSubscription)?>(nil)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            // Only the subscription is kept, exactly as `LiveTestSSEClient` does.
            let opened = client.openSseStream(
                request: NetworkRequest(url: URL(string: "https://api.digia.cloud/live/connect")!, method: .post),
                handler: RecordingSseHandler(received: received) { done.resume() }
            )
            subscription.mutate { $0 = opened }
        }
        subscription.value?.cancel()

        #expect(received.value == ["open", "connected", "campaign_test", "closed"])
    }

    // MARK: - SSEFrameParser Tests

    @Test("SSEFrameParser parses complete frames with id, event, and multiline data")
    func sseFrameParserMultiline() {
        var parser = SSEFrameParser()

        let chunk1 = "id: 42\nevent: update\ndata: first line\n"
        let frames1 = parser.feed(Data(chunk1.utf8))
        #expect(frames1.isEmpty) // Not finished until empty newline

        let chunk2 = "data: second line\n\n"
        let frames2 = parser.feed(Data(chunk2.utf8))
        #expect(frames2.count == 1)

        let event = frames2[0]
        #expect(event.id == "42")
        #expect(event.event == "update")
        #expect(event.data == "first line\nsecond line")
    }

    @Test("SSEFrameParser handles comments and reset")
    func sseFrameParserComments() {
        var parser = SSEFrameParser()

        let chunk = ": ping comment\ndata: payload\n\n"
        let frames = parser.feed(Data(chunk.utf8))
        #expect(frames.count == 1)
        #expect(frames[0].data == "payload")
        #expect(frames[0].event == nil)
        #expect(frames[0].id == nil)

        parser = SSEFrameParser()
        let framesAfterReset = parser.feed(Data("\n\n".utf8))
        #expect(framesAfterReset.isEmpty)
    }

    @Test("SSEFrameParser survives chunks split mid-character and across CRLF boundaries")
    func sseFrameParserChunkBoundaries() {
        var parser = SSEFrameParser()
        let wire = Data("event: greet\r\ndata:  héllo 👋 \r\ndata:x\r\n\r\nid: 7\rdata: b\r\r".utf8)
        // Every split point, including inside "é", "👋" and each "\r\n".
        for split in 1..<wire.count {
            var parser = SSEFrameParser()
            let frames = parser.feed(wire.prefix(split)) + parser.feed(wire.dropFirst(split))
            #expect(frames == [
                SseEvent(id: nil, event: "greet", data: " héllo 👋 \nx"),
                SseEvent(id: "7", event: nil, data: "b"),
            ], "split at \(split)")
        }
        #expect(parser.feed(Data("data: one\n\n".utf8)) == [SseEvent(data: "one")])
    }
}

/// A value shared with a `MockURLProtocol` handler, which runs off the test's thread.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value { lock.withLock { stored } }

    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// Records callbacks and reports the terminal one. Nothing outside the stream
/// holds it, so it lives only as long as the client keeps it.
private final class RecordingSseHandler: SseStreamHandler, @unchecked Sendable {
    private let received: LockedBox<[String]>
    private let onTerminal: () -> Void

    init(received: LockedBox<[String]>, onTerminal: @escaping () -> Void) {
        self.received = received
        self.onTerminal = onTerminal
    }

    func onOpen() { received.mutate { $0.append("open") } }
    func onEvent(_ event: SseEvent) { received.mutate { $0.append(event.event ?? "") } }
    func onError(_ error: Error) { received.mutate { $0.append("error") }; onTerminal() }
    func onClosed() { received.mutate { $0.append("closed") }; onTerminal() }
}
