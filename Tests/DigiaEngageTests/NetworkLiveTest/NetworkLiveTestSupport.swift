import Foundation
@testable import DigiaEngage

// MARK: - A transport that only records

/// A `NetworkClient` that records every SSE connect and hands the test the handler the
/// live-test code gave it. Unlike `MockNetworkClient`, it never calls back on its own (no
/// `onOpen` at connect, no `onClosed` on cancel), so each callback a test sends is the only one
/// the code under test sees — as with Flutter's `MockNetworkClient` in `live_test_sse_client_test`.
final class NetworkLiveTestTransport: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [NetworkRequest] = []
    private var streams: [(handler: any SseStreamHandler, subscription: NetworkLiveTestSubscription)] = []

    /// How many times a stream has been opened.
    var connects: Int { lock.withLock { requests.count } }
    var recordedRequests: [NetworkRequest] { lock.withLock { requests } }
    /// Streams opened and not yet cancelled by the client.
    var openStreams: Int { lock.withLock { streams.filter { !$0.subscription.isCancelled }.count } }
    /// The handler of the most recent connection.
    var handler: any SseStreamHandler { lock.withLock { streams.last!.handler } }

    /// The body of the most recent connect, decoded.
    var lastConnectBody: [String: String]? {
        guard let body = recordedRequests.last?.body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
    }

    func send(_ event: String?, _ data: String) {
        handler.onEvent(SseEvent(event: event, data: data))
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: nil)
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: nil)
    }

    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        let subscription = NetworkLiveTestSubscription()
        lock.withLock {
            requests.append(request)
            streams.append((handler, subscription))
        }
        return subscription
    }
}

final class NetworkLiveTestSubscription: CancellableSubscription, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

// MARK: - Waiting

/// Polls `condition` on the main actor until it holds or `timeout` passes; returns whether it
/// held. `LiveTestSSEClient`'s stream handler hops each callback onto the main actor in a Task,
/// so a callback's effect is never visible synchronously.
@MainActor
@discardableResult
func networkLiveTestWait(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

/// Lets queued main-actor hops run, for asserting that something did *not* happen.
@MainActor
func networkLiveTestDrain(_ seconds: TimeInterval = 0.05) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// MARK: - URLProtocol stub

/// Serves `URLSessionNetworkClient` requests from a script. Its own static state (not
/// `MockURLProtocol`'s), so its suite does not race the existing network suite. Each scripted
/// reply is a response, then body chunks delivered one by one, then finish / fail / stay open.
final class NetworkLiveTestURLProtocol: URLProtocol, @unchecked Sendable {
    enum Ending: Sendable { case finish, fail(URLError), stayOpen }
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var ending: Ending = .finish
        /// Fails the request before any response, as a dropped connection does.
        var transportError: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var reply = Reply()
    nonisolated(unsafe) private static var captured: [(request: URLRequest, body: Data?)] = []
    nonisolated(unsafe) private static var stopped = 0

    static func serve(_ reply: Reply) {
        lock.withLock {
            self.reply = reply
            captured = []
            stopped = 0
        }
    }

    static var requests: [(request: URLRequest, body: Data?)] { lock.withLock { captured } }
    /// How many loads URLSession has stopped (a cancelled stream stops its load).
    static var stopCount: Int { lock.withLock { stopped } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NetworkLiveTestURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.lock.withLock { () -> Reply in
            Self.captured.append((request, Self.readBody(of: request)))
            return Self.reply
        }
        if let error = reply.transportError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        switch reply.ending {
        case .finish:
            for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let error):
            // A stream that dies after it opened: the response and data first, the failure
            // later, as on a real socket. Delivered all at once, URLSession folds the failure
            // into `bytes(for:)` and the stream never opens.
            for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { [self] in
                client?.urlProtocol(self, didFailWithError: error)
            }
        case .stayOpen:
            for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.stopped += 1 }
    }

    /// URLSession hands a protocol the body as a stream, not `httpBody`.
    private static func readBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Records SSE callbacks in order: "open", "event:<name>|<data>", "error:<description>",
/// "closed".
final class NetworkLiveTestSseRecorder: SseStreamHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var eventList: [SseEvent] = []
    private var errorList: [Error] = []

    var callbacks: [String] { lock.withLock { log } }
    var events: [SseEvent] { lock.withLock { eventList } }
    var errors: [Error] { lock.withLock { errorList } }
    var terminals: [String] { callbacks.filter { $0 == "closed" || $0.hasPrefix("error") } }

    func onOpen() { lock.withLock { log.append("open") } }
    func onEvent(_ event: SseEvent) {
        lock.withLock {
            log.append("event")
            eventList.append(event)
        }
    }
    func onError(_ error: Error) {
        lock.withLock {
            log.append("error")
            errorList.append(error)
        }
    }
    func onClosed() { lock.withLock { log.append("closed") } }
}
