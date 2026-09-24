import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

public struct NetworkRequest: Sendable {
    public let url: URL
    public let method: HTTPMethod
    public let headers: [String: String]
    public let body: Data?
    public let connectTimeout: TimeInterval?
    public let readTimeout: TimeInterval?

    public init(
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

    public init(
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

    public var timeoutInterval: TimeInterval? {
        readTimeout ?? connectTimeout
    }
}

public struct NetworkResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data?
    public let isSuccessful: Bool

    public init(
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

    public init(
        statusCode: Int,
        headers: [String: String],
        data: Data
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = data
        self.isSuccessful = (200...299).contains(statusCode)
    }

    public var data: Data? {
        body
    }

    public var stringBody: String? {
        body.flatMap { String(data: $0, encoding: .utf8) }
    }
}

public struct MultipartFilePart: Sendable {
    public let fieldName: String
    public let fileName: String
    public let mimeType: String
    public let data: Data

    public init(
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

public struct MultipartUploadRequest: Sendable {
    public let url: URL
    public let headers: [String: String]
    public let formFields: [String: String]
    public let files: [MultipartFilePart]
    public let timeout: TimeInterval

    public init(
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

    public init(
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

    public var timeoutInterval: TimeInterval {
        timeout
    }
}

public struct SseEvent: Sendable, Equatable {
    public let id: String?
    public let event: String?
    public let data: String

    public init(id: String? = nil, event: String? = nil, data: String) {
        self.id = id
        self.event = event
        self.data = data
    }
}

public typealias SSEEvent = SseEvent

public protocol SseStreamHandler: AnyObject, Sendable {
    func onOpen()
    func onEvent(_ event: SseEvent)
    func onError(_ error: Error)
    func onClosed()
}

public typealias SSEStreamHandler = SseStreamHandler

public protocol CancellableSubscription: AnyObject, Sendable {
    func cancel()
}

public typealias CancellableTask = CancellableSubscription

public protocol NetworkClient: AnyObject, Sendable {
    func execute(request: NetworkRequest) async throws -> NetworkResponse
    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse
    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription
}

public extension NetworkClient {
    func openSSEStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        openSseStream(request: request, handler: handler)
    }
}
