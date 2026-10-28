import Foundation
import Testing
@testable import DigiaEngage

/// What the production network client sends and hands back: the JSON request path, the multipart
/// upload page capture uses, the SSE stream live test uses, and how failures arrive. Driven
/// through `URLSessionNetworkClient` with a `URLProtocol` stub on its injected session, so the
/// real request assembly and response mapping run.
///
/// Port of `flutter/core/test/network/dio_network_client_test.dart` and
/// `flutter/core/test/network/sse_stream_test.dart` (transport half). Header precedence and the
/// session header (`common_headers_test`, `session_header_test`) are already covered by
/// `Network/NetworkClientTests.swift`, as is SSEFrameParser's every-split-point test.
@Suite("Network: URLSession client", .serialized, .tags(.unit, .network))
struct NetworkLiveTestURLSessionClientTests {

    private let url = URL(string: "https://example.test/track")!

    private func client(
        headers: @escaping @Sendable () -> [String: String] = { ["X-Digia-Project-Id": "project"] }
    ) -> URLSessionNetworkClient {
        URLSessionNetworkClient(
            session: NetworkLiveTestURLProtocol.session(),
            sessionIdProvider: { nil },
            headerProvider: headers
        )
    }

    // MARK: - A JSON request

    @Test("is sent to its URL with its method and body, typed JSON unless the caller says otherwise")
    func jsonRequestShape() async throws {
        NetworkLiveTestURLProtocol.serve(.init())
        let client = client()

        _ = try await client.execute(request: NetworkRequest(url: url, method: .post, body: Data(#"{"a":1}"#.utf8)))
        _ = try await client.execute(request: NetworkRequest(
            url: url, method: .post, headers: ["Content-Type": "text/plain"], body: Data("x".utf8)))
        _ = try await client.execute(request: NetworkRequest(url: url))

        let sent = NetworkLiveTestURLProtocol.requests
        try #require(sent.count == 3)
        #expect(sent[0].request.url == url)
        #expect(sent[0].request.httpMethod == "POST")
        #expect(sent[0].body == Data(#"{"a":1}"#.utf8))
        // Fails if: URLSessionNetworkClient.execute stops defaulting Content-Type for a body
        // (the `== nil` check around `application/json`), or overwrites the caller's.
        #expect(sent[0].request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent[1].request.value(forHTTPHeaderField: "Content-Type") == "text/plain")
        // A bodiless GET is not given a body type.
        #expect(sent[2].request.httpMethod == "GET")
        #expect(sent[2].request.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test("reads a fresh common header on every request")
    func commonHeadersAreReadPerRequest() async throws {
        NetworkLiveTestURLProtocol.serve(.init())
        let project = LockedBox("one")
        let client = client(headers: { ["X-Digia-Project-Id": project.value] })

        _ = try await client.execute(request: NetworkRequest(url: url))
        project.mutate { $0 = "two" }
        _ = try await client.execute(request: NetworkRequest(url: url))

        // Fails if: URLSessionNetworkClient captures `headerProvider()` once at init instead of
        // calling it in assembleHeaders — a project switch would keep sending the old id.
        #expect(NetworkLiveTestURLProtocol.requests.map { $0.request.value(forHTTPHeaderField: "X-Digia-Project-Id") }
            == ["one", "two"])
    }

    @Test("uses the read timeout, else the connect timeout, as the request timeout")
    func requestTimeout() async throws {
        NetworkLiveTestURLProtocol.serve(.init())
        let client = client()

        _ = try await client.execute(request: NetworkRequest(url: url, connectTimeout: 3, readTimeout: 4))
        _ = try await client.execute(request: NetworkRequest(url: url, connectTimeout: 3))

        // Fails if: NetworkRequest.timeoutInterval prefers connectTimeout, or execute stops
        // applying it to the URLRequest.
        #expect(NetworkLiveTestURLProtocol.requests.map(\.request.timeoutInterval) == [4, 3])
    }

    @Test("hands back the status, headers and raw body; a failing status is a response, not a throw")
    func responseMapping() async throws {
        let client = client()

        NetworkLiveTestURLProtocol.serve(.init(status: 201, headers: ["x-trace": "a"], chunks: [Data(#"{"ok":true}"#.utf8)]))
        let ok = try await client.execute(request: NetworkRequest(url: url))
        #expect(ok.statusCode == 201)
        #expect(ok.stringBody == #"{"ok":true}"#)
        #expect(ok.headers.first { $0.key.lowercased() == "x-trace" }?.value == "a")
        #expect(ok.isSuccessful)

        NetworkLiveTestURLProtocol.serve(.init(status: 503, chunks: [Data("nope".utf8)]))
        let failing = try await client.execute(request: NetworkRequest(url: url))
        // Fails if: execute derives isSuccessful from anything but the 2xx range.
        #expect(failing.statusCode == 503)
        #expect(failing.stringBody == "nope")
        #expect(!failing.isSuccessful)
    }

    @Test("reports a request that did not complete as the transport's error")
    func transportFailureThrows() async {
        NetworkLiveTestURLProtocol.serve(.init(transportError: URLError(.notConnectedToInternet)))

        // Fails if: execute swallows the URLSession error into a synthetic response — callers
        // (analytics retry, ACK retry) tell "offline" from "server said no" by the throw.
        await #expect(throws: URLError.self) {
            _ = try await client().execute(request: NetworkRequest(url: url))
        }
    }

    // MARK: - A multipart upload

    @Test("is a form-data POST carrying each field and each file under its own part")
    func multipartBody() async throws {
        NetworkLiveTestURLProtocol.serve(.init(status: 413, chunks: [Data("too large".utf8)]))
        let request = MultipartUploadRequest(
            url: URL(string: "https://example.test/upload")!,
            headers: ["X-Upload": "yes", "X-Digia-Project-Id": "upload-project"],
            formFields: ["meta": #"{"page":"home"}"#],
            files: [
                MultipartFilePart(fieldName: "screenshot", fileName: "home.dat", mimeType: "image/png", data: Data([9, 8, 7])),
                MultipartFilePart(fieldName: "tree", fileName: "tree.dat", mimeType: "application/json", data: Data("{}".utf8)),
            ],
            timeout: 45
        )

        let response = try await client().executeMultipart(request: request)

        // The server's answer comes back, failing status included.
        #expect(response.statusCode == 413)
        #expect(response.stringBody == "too large")

        let sent = try #require(NetworkLiveTestURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.timeoutInterval == 45)
        // Its own headers over the common ones, and the common ones still go out.
        #expect(sent.request.value(forHTTPHeaderField: "X-Upload") == "yes")
        #expect(sent.request.value(forHTTPHeaderField: "X-Digia-Project-Id") == "upload-project")
        #expect(sent.request.value(forHTTPHeaderField: "X-Digia-Platform") == "ios")

        let contentType = try #require(sent.request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = try #require(sent.body)

        // Fails if: executeMultipart drops a part, mislabels a file's field/name/type, corrupts
        // the bytes, or omits the closing boundary (the server then rejects the whole upload).
        var expected = Data()
        expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"meta\"\r\n\r\n{\"page\":\"home\"}\r\n".utf8))
        expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"screenshot\"; filename=\"home.dat\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        expected.append(Data([9, 8, 7]))
        expected.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"tree\"; filename=\"tree.dat\"\r\nContent-Type: application/json\r\n\r\n{}\r\n".utf8))
        expected.append(Data("--\(boundary)--\r\n".utf8))
        #expect(body == expected)
    }

    @Test("reports an upload that did not complete as the transport's error")
    func multipartTransportFailureThrows() async {
        NetworkLiveTestURLProtocol.serve(.init(transportError: URLError(.timedOut)))

        await #expect(throws: URLError.self) {
            _ = try await client().executeMultipart(request: MultipartUploadRequest(url: URL(string: "https://example.test/upload")!))
        }
    }

    // MARK: - An SSE stream

    private func openStream(
        _ client: URLSessionNetworkClient,
        headers: [String: String] = [:],
        body: Data? = nil
    ) -> (NetworkLiveTestSseRecorder, any CancellableSubscription) {
        let recorder = NetworkLiveTestSseRecorder()
        let subscription = client.openSseStream(
            request: NetworkRequest(url: URL(string: "https://example.test/sse")!, method: .post, headers: headers, body: body),
            handler: recorder
        )
        return (recorder, subscription)
    }

    @Test("asks for an uncached event stream unless the caller says otherwise, and types a JSON body")
    func sseRequestHeaders() async throws {
        NetworkLiveTestURLProtocol.serve(.init())
        let client = client()

        let (first, _) = openStream(client, body: Data("{}".utf8))
        await networkLiveTestWait { first.terminals.count == 1 }
        let (second, _) = openStream(client, headers: ["Accept": "application/x-ndjson", "Cache-Control": "max-age=5"])
        await networkLiveTestWait { second.terminals.count == 1 }

        let sent = NetworkLiveTestURLProtocol.requests.map(\.request)
        try #require(sent.count == 2)
        // Fails if: openSseStream stops defaulting Accept / Cache-Control (a proxy may then
        // buffer or cache the stream), or overwrites a caller's value.
        #expect(sent[0].value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(sent[0].value(forHTTPHeaderField: "Cache-Control") == "no-cache")
        #expect(sent[0].value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent[0].httpMethod == "POST")
        #expect(sent[1].value(forHTTPHeaderField: "Accept") == "application/x-ndjson")
        #expect(sent[1].value(forHTTPHeaderField: "Cache-Control") == "max-age=5")
    }

    @Test("frames split mid-character and across CRLF line endings arrive whole, then the stream closes")
    func sseChunkedFrames() async throws {
        let stream = "event: greet\r\ndata: héllo €\r\n\r\n"
            + ": heartbeat\n"
            + "data: a\ndata:  b\n\n"
            + "id: 7\rdata:c\r\r"
        let bytes = Data(stream.utf8)
        func offset(of s: String) -> Int { Data(stream[..<stream.range(of: s)!.lowerBound].utf8).count }
        let cuts = [
            offset(of: "é") + 1,           // inside the 2-byte é
            offset(of: "€") + 2,           // inside the 3-byte €
            offset(of: "\r\n\r\n") + 1,    // between CR and LF
            offset(of: "\r\n\r\n") + 3,    // between the second CR and LF
        ]
        let bounds = [0] + cuts + [bytes.count]
        let chunks = (0..<(bounds.count - 1)).map { bytes.subdata(in: bounds[$0]..<bounds[$0 + 1]) }
        NetworkLiveTestURLProtocol.serve(.init(headers: ["Content-Type": "text/event-stream"], chunks: chunks))

        let (recorder, _) = openStream(client())
        #expect(await networkLiveTestWait { recorder.terminals.count == 1 })

        // Fails if: openSseStream decodes per chunk instead of feeding bytes to SSEFrameParser,
        // or SSEFrameParser decodes a line before it is complete.
        #expect(recorder.events == [
            SseEvent(id: nil, event: "greet", data: "héllo €"),
            SseEvent(id: nil, event: nil, data: "a\n b"),
            SseEvent(id: "7", event: nil, data: "c"),
        ])
        #expect(recorder.callbacks.first == "open")
        #expect(recorder.callbacks.last == "closed")
    }

    @Test("a non-2xx connect ends in exactly one terminal callback: an error carrying the status")
    func sseRejectedConnect() async throws {
        NetworkLiveTestURLProtocol.serve(.init(status: 500, chunks: [Data("oops".utf8)]))

        let (recorder, _) = openStream(client())
        #expect(await networkLiveTestWait { !recorder.terminals.isEmpty })
        await networkLiveTestDrain()

        // Fails if: openSseStream calls onOpen before checking the status, or reports a
        // rejection as onClosed — LiveTestSSEClient then cannot tell a refused key (401/403,
        // stop) from a hiccup (reconnect).
        #expect(recorder.callbacks == ["error"])
        #expect((recorder.errors.first as? SseHTTPStatusError)?.statusCode == 500)
    }

    @Test("a transport failure mid-stream ends in onError, never onClosed")
    func sseDroppedMidStream() async throws {
        NetworkLiveTestURLProtocol.serve(.init(
            headers: ["Content-Type": "text/event-stream"], chunks: [Data("data: one\n\n".utf8)], ending: .fail(URLError(.networkConnectionLost))))

        let (recorder, _) = openStream(client())
        #expect(await networkLiveTestWait { !recorder.terminals.isEmpty })
        await networkLiveTestDrain()

        #expect(recorder.callbacks == ["open", "event", "error"])
    }

    @Test("cancelling an open stream releases its connection and reports nothing afterwards")
    func sseCancelIsSilent() async throws {
        NetworkLiveTestURLProtocol.serve(.init(headers: ["Content-Type": "text/event-stream"], chunks: [Data("data: one\n\n".utf8)], ending: .stayOpen))

        let (recorder, subscription) = openStream(client())
        #expect(await networkLiveTestWait { recorder.events.count == 1 })
        subscription.cancel()

        // The load is torn down rather than left to drain…
        #expect(await networkLiveTestWait { NetworkLiveTestURLProtocol.stopCount >= 1 })
        await networkLiveTestDrain(0.1)
        // Fails if: openSseStream's catch drops its `subscription.isCancelled` guard — the
        // cancellation then surfaces as an onError, and LiveTestSSEClient schedules a reconnect
        // for a stream the caller stopped on purpose.
        #expect(recorder.callbacks == ["open", "event"])
    }
}
