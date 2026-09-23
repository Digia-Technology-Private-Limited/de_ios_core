import Foundation
@testable import DigiaEngage

public final class MockNetworkClient: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()

    public private(set) var recordedRequests: [NetworkRequest] = []
    public private(set) var recordedMultipartRequests: [MultipartUploadRequest] = []
    private var responses: [String: NetworkResponse] = [:]
    private var responseQueue: [NetworkResponse] = []
    private var responseFactory: ((NetworkRequest) -> NetworkResponse?)?
    private var simulatedException: (any Error)?
    private var activeStreamHandlers: [any SseStreamHandler] = []

    public init() {}

    public var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.count
    }

    public var multipartRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedMultipartRequests.count
    }

    public var lastRequest: NetworkRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests.last
    }

    public var lastMultipartRequest: MultipartUploadRequest? {
        lock.lock()
        defer { lock.unlock() }
        return recordedMultipartRequests.last
    }

    public func enqueueResponse(
        url: String,
        statusCode: Int,
        body: String = "",
        headers: [String: String] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        responses[url] = NetworkResponse(
            statusCode: statusCode,
            headers: headers,
            body: body.data(using: .utf8),
            isSuccessful: (200...299).contains(statusCode)
        )
    }

    public func enqueueResponse(
        url: URL,
        statusCode: Int,
        body: String = "",
        headers: [String: String] = [:]
    ) {
        enqueueResponse(url: url.absoluteString, statusCode: statusCode, body: body, headers: headers)
    }

    public func enqueueResponse(
        url: String,
        statusCode: Int,
        data: Data,
        headers: [String: String] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        responses[url] = NetworkResponse(
            statusCode: statusCode,
            headers: headers,
            body: data,
            isSuccessful: (200...299).contains(statusCode)
        )
    }

    public func enqueueResponse(
        statusCode: Int = 200,
        body: String = "",
        headers: [String: String] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        responseQueue.append(NetworkResponse(
            statusCode: statusCode,
            headers: headers,
            body: body.data(using: .utf8),
            isSuccessful: (200...299).contains(statusCode)
        ))
    }

    public func enqueueResponse(
        statusCode: Int = 200,
        body: Data?,
        headers: [String: String] = [:]
    ) {
        lock.lock()
        defer { lock.unlock() }
        responseQueue.append(NetworkResponse(
            statusCode: statusCode,
            headers: headers,
            body: body,
            isSuccessful: (200...299).contains(statusCode)
        ))
    }

    public func enqueueResponse(_ response: NetworkResponse) {
        lock.lock()
        defer { lock.unlock() }
        responseQueue.append(response)
    }

    public func setResponseFactory(_ factory: @escaping (NetworkRequest) -> NetworkResponse?) {
        lock.lock()
        defer { lock.unlock() }
        self.responseFactory = factory
    }

    public func simulateTransportError(_ error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        self.simulatedException = error
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.removeAll()
        recordedMultipartRequests.removeAll()
        responses.removeAll()
        responseQueue.removeAll()
        responseFactory = nil
        simulatedException = nil
        activeStreamHandlers.removeAll()
    }

    // MARK: - Synchronous Helpers for Thread Safety

    private func recordAndResolve(request: NetworkRequest) -> (
        error: (any Error)?,
        factory: ((NetworkRequest) -> NetworkResponse?)?,
        matching: NetworkResponse?,
        queued: NetworkResponse?
    ) {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        let error = simulatedException
        let factory = responseFactory
        let matching = responses[request.url.absoluteString]
        let queued = !responseQueue.isEmpty ? responseQueue.removeFirst() : nil
        return (error, factory, matching, queued)
    }

    private func recordAndResolveMultipart(request: MultipartUploadRequest) -> (
        error: (any Error)?,
        matching: NetworkResponse?,
        queued: NetworkResponse?
    ) {
        lock.lock()
        defer { lock.unlock() }
        recordedMultipartRequests.append(request)
        let error = simulatedException
        let matching = responses[request.url.absoluteString]
        let queued = !responseQueue.isEmpty ? responseQueue.removeFirst() : nil
        return (error, matching, queued)
    }

    // MARK: - NetworkClient

    public func execute(request: NetworkRequest) async throws -> NetworkResponse {
        let (error, factory, matchingResponse, queuedResponse) = recordAndResolve(request: request)

        if let error {
            throw error
        }

        if let factory, let response = factory(request) {
            return response
        }

        if let matchingResponse {
            return matchingResponse
        }

        if let queuedResponse {
            return queuedResponse
        }

        return NetworkResponse(statusCode: 404, headers: [:], body: Data(), isSuccessful: false)
    }

    public func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        let (error, matchingResponse, queuedResponse) = recordAndResolveMultipart(request: request)

        if let error {
            throw error
        }

        if let matchingResponse {
            return matchingResponse
        }

        if let queuedResponse {
            return queuedResponse
        }

        return NetworkResponse(statusCode: 404, headers: [:], body: Data(), isSuccessful: false)
    }

    public func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        lock.lock()
        recordedRequests.append(request)
        let error = simulatedException
        activeStreamHandlers.append(handler)
        lock.unlock()

        if let error {
            handler.onError(error)
        } else {
            handler.onOpen()
        }

        return MockSubscription { [weak self, weak handler] in
            guard let self, let handler else { return }
            self.lock.lock()
            self.activeStreamHandlers.removeAll { $0 === handler }
            self.lock.unlock()
            handler.onClosed()
        }
    }

    public func emitSseEvent(_ event: SseEvent) {
        lock.lock()
        let handlers = activeStreamHandlers
        lock.unlock()
        for handler in handlers {
            handler.onEvent(event)
        }
    }

    public func emitSseError(_ error: any Error) {
        lock.lock()
        let handlers = activeStreamHandlers
        lock.unlock()
        for handler in handlers {
            handler.onError(error)
        }
    }

    public func emitSseClosed() {
        lock.lock()
        let handlers = activeStreamHandlers
        activeStreamHandlers.removeAll()
        lock.unlock()
        for handler in handlers {
            handler.onClosed()
        }
    }
}

private final class MockSubscription: CancellableSubscription, @unchecked Sendable {
    private let onCancel: () -> Void
    private let lock = NSLock()
    private var isCancelled = false

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        lock.unlock()
        onCancel()
    }
}
