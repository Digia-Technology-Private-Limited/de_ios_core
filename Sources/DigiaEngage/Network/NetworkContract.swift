import Foundation

enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

struct NetworkRequest: Sendable {
    let url: URL
    let method: HTTPMethod
    let headers: [String: String]
    let body: Data?
    let connectTimeout: TimeInterval?
    let readTimeout: TimeInterval?

    init(
        url: URL,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        connectTimeout: TimeInterval? = nil,
        readTimeout: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.connectTimeout = connectTimeout
        self.readTimeout = readTimeout
    }

    init(
        url: String,
        method: HTTPMethod = .get,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutInterval: TimeInterval? = nil
    ) {
        self.url = URL(string: url) ?? URL(fileURLWithPath: "/")
        self.method = method
        self.headers = headers
        self.body = body
        self.connectTimeout = timeoutInterval
        self.readTimeout = timeoutInterval
    }

    var timeoutInterval: TimeInterval? {
        readTimeout ?? connectTimeout
    }
}

struct NetworkResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data?
    let isSuccessful: Bool

    init(
        statusCode: Int,
        headers: [String: String],
        body: Data?,
        isSuccessful: Bool? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.isSuccessful = isSuccessful ?? (200...299).contains(statusCode)
    }

    init(
        statusCode: Int,
        headers: [String: String],
        data: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = data
        self.isSuccessful = (200...299).contains(statusCode)
    }

    var data: Data? {
        body
    }

    var stringBody: String? {
        body.flatMap { String(data: $0, encoding: .utf8) }
    }
}

struct MultipartFilePart: Sendable {
    let fieldName: String
    let fileName: String
    let mimeType: String
    let data: Data

    init(
        fieldName: String,
        fileName: String,
        mimeType: String,
        data: Data
    ) {
        self.fieldName = fieldName
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }
}

struct MultipartUploadRequest: Sendable {
    let url: URL
    let headers: [String: String]
    let formFields: [String: String]
    let files: [MultipartFilePart]
    let timeout: TimeInterval

    init(
        url: URL,
        headers: [String: String] = [:],
        formFields: [String: String] = [:],
        files: [MultipartFilePart] = [],
        timeout: TimeInterval = 30
    ) {
        self.url = url
        self.headers = headers
        self.formFields = formFields
        self.files = files
        self.timeout = timeout
    }

    init(
        url: String,
        headers: [String: String] = [:],
        formFields: [String: String] = [:],
        files: [MultipartFilePart] = [],
        timeoutInterval: TimeInterval = 30
    ) {
        self.url = URL(string: url) ?? URL(fileURLWithPath: "/")
        self.headers = headers
        self.formFields = formFields
        self.files = files
        self.timeout = timeoutInterval
    }

    var timeoutInterval: TimeInterval {
        timeout
    }
}

struct SseEvent: Sendable, Equatable {
    let id: String?
    let event: String?
    let data: String

    init(id: String? = nil, event: String? = nil, data: String) {
        self.id = id
        self.event = event
        self.data = data
    }
}

typealias SSEEvent = SseEvent

protocol SseStreamHandler: AnyObject, Sendable {
    func onOpen()
    func onEvent(_ event: SseEvent)
    func onError(_ error: Error)
    func onClosed()
}

typealias SSEStreamHandler = SseStreamHandler

protocol CancellableSubscription: AnyObject, Sendable {
    func cancel()
}

typealias CancellableTask = CancellableSubscription

protocol NetworkClient: AnyObject, Sendable {
    func execute(request: NetworkRequest) async throws -> NetworkResponse
    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse
    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription
}

extension NetworkClient {
    func openSSEStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        openSseStream(request: request, handler: handler)
    }
}
