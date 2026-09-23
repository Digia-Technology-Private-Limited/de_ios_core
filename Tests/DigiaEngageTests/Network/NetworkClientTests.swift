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

    // MARK: - MockNetworkClient Tests

    @Test("MockNetworkClient records requests and serves enqueued responses")
    func mockClientBasicExecution() async throws {
        let mock = MockNetworkClient()
        mock.enqueueResponse(
            statusCode: 200,
            body: #"{"status":"ok"}"#,
            headers: ["X-Custom": "val"]
        )

        let request = NetworkRequest(
            url: URL(string: "https://api.digia.cloud/v1/test")!,
            method: .post,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"hello\":1}".utf8)
        )

        let response = try await mock.execute(request: request)
        #expect(response.statusCode == 200)
        #expect(response.isSuccessful)
        #expect(response.headers["X-Custom"] == "val")
        #expect(response.body != nil)

        #expect(mock.requestCount == 1)
        #expect(mock.lastRequest?.url == request.url)
        #expect(mock.lastRequest?.method == .post)

        mock.reset()
        #expect(mock.requestCount == 0)
        #expect(mock.lastRequest == nil)
    }

    @Test("MockNetworkClient matches responses by URL")
    func mockClientURLMatching() async throws {
        let mock = MockNetworkClient()
        let url1 = URL(string: "https://api.digia.cloud/v1/one")!
        let url2 = URL(string: "https://api.digia.cloud/v1/two")!

        mock.enqueueResponse(url: url1, statusCode: 201, body: "one")
        mock.enqueueResponse(url: url2, statusCode: 202, body: "two")

        let resp2 = try await mock.execute(request: NetworkRequest(url: url2))
        let resp1 = try await mock.execute(request: NetworkRequest(url: url1))

        #expect(resp2.statusCode == 202)
        #expect(resp1.statusCode == 201)
    }

    @Test("MockNetworkClient simulates transport errors")
    func mockClientTransportError() async {
        let mock = MockNetworkClient()
        mock.simulateTransportError(URLError(.notConnectedToInternet))

        do {
            _ = try await mock.execute(request: NetworkRequest(url: URL(string: "https://api.digia.cloud")!))
            #expect(Bool(false), "Expected error to be thrown")
        } catch let err as URLError {
            #expect(err.code == .notConnectedToInternet)
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test("MockNetworkClient multipart upload recording")
    func mockClientMultipartUpload() async throws {
        let mock = MockNetworkClient()
        mock.enqueueResponse(statusCode: 200)

        let part = MultipartFilePart(
            fieldName: "video",
            fileName: "capture.mp4",
            mimeType: "video/mp4",
            data: Data([0x00, 0x01, 0x02])
        )
        let uploadReq = MultipartUploadRequest(
            url: URL(string: "https://api.digia.cloud/v1/upload")!,
            headers: ["X-Digia-Project-Id": "proj_123"],
            formFields: ["sessionId": "sess_abc"],
            files: [part]
        )

        let response = try await mock.executeMultipart(request: uploadReq)
        #expect(response.statusCode == 200)
        #expect(mock.multipartRequestCount == 1)
        #expect(mock.lastMultipartRequest?.files.count == 1)
        #expect(mock.lastMultipartRequest?.formFields["sessionId"] == "sess_abc")
    }

    final class StreamRecorder: SseStreamHandler, @unchecked Sendable {
        private let lock = NSLock()
        var opened = false
        var events: [SseEvent] = []
        var errors: [any Error] = []
        var closed = false

        func onOpen() {
            lock.lock()
            defer { lock.unlock() }
            opened = true
        }

        func onEvent(_ event: SseEvent) {
            lock.lock()
            defer { lock.unlock() }
            events.append(event)
        }

        func onError(_ error: any Error) {
            lock.lock()
            defer { lock.unlock() }
            errors.append(error)
        }

        func onClosed() {
            lock.lock()
            defer { lock.unlock() }
            closed = true
        }
    }

    @Test("MockNetworkClient simulates SSE stream events")
    func mockClientSseStreaming() {
        let mock = MockNetworkClient()
        let handler = StreamRecorder()
        let sub = mock.openSseStream(
            request: NetworkRequest(url: URL(string: "https://api.digia.cloud/v1/stream")!),
            handler: handler
        )

        #expect(handler.opened)
        mock.emitSseEvent(SseEvent(id: "1", event: "message", data: "test-data"))
        #expect(handler.events.count == 1)
        #expect(handler.events.first?.data == "test-data")

        mock.emitSseError(URLError(.networkConnectionLost))
        #expect(handler.errors.count == 1)

        mock.emitSseClosed()
        #expect(handler.closed)

        sub.cancel()
    }

    // MARK: - URLSessionNetworkClient Header Duplication & Contract Tests

    @Test("URLSessionNetworkClient injects duplicate headers and platform tag")
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

        // 1. Verify assembled headers dictionary contains BOTH casings
        let assembled = client.assembleHeaders(for: request.headers)
        #expect(assembled["X-Digia-Project-Id"] == "proj_p1")
        #expect(assembled["x-digia-project-id"] == "proj_p1")
        #expect(assembled["X-Digia-Device-Id"] == "dev_d1")
        #expect(assembled["x-digia-device-id"] == "dev_d1")
        #expect(assembled["X-Digia-Platform"] == "ios")
        #expect(assembled["x-digia-platform"] == "ios")
        #expect(assembled["X-Digia-Sdk-Version"] == DigiaSdkVersion.value)
        #expect(assembled["x-digia-sdk-version"] == DigiaSdkVersion.value)
        #expect(assembled["X-Custom"] == "CustomVal")

        // 2. Verify wire URLRequest delivers the headers
        let wireRequest = try #require(capturedRequest)
        #expect(wireRequest.value(forHTTPHeaderField: "X-Digia-Project-Id") == "proj_p1")
        #expect(wireRequest.value(forHTTPHeaderField: "x-digia-project-id") == "proj_p1")
        #expect(wireRequest.value(forHTTPHeaderField: "X-Digia-Device-Id") == "dev_d1")
        #expect(wireRequest.value(forHTTPHeaderField: "x-digia-device-id") == "dev_d1")
        #expect(wireRequest.value(forHTTPHeaderField: "X-Digia-Platform") == "ios")
        #expect(wireRequest.value(forHTTPHeaderField: "X-Custom") == "CustomVal")
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
}
