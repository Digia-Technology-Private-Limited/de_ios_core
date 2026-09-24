import Foundation

public final class URLSessionNetworkClient: NetworkClient, @unchecked Sendable {
    private let session: URLSession
    private let uploadSession: URLSession
    private let sseSession: URLSession
    private let sessionIdProvider: (@Sendable () -> String?)?
    private let headerProvider: (@Sendable () -> [String: String])?
    private let lock = NSLock()
    private var staticHeaders: [String: String] = [:]

    public init(
        session: URLSession? = nil,
        sessionIdProvider: (@Sendable () -> String?)? = nil,
        headerProvider: (@Sendable () -> [String: String])? = nil
    ) {
        self.sessionIdProvider = sessionIdProvider
        self.headerProvider = headerProvider
        if let session {
            self.session = session
            self.uploadSession = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: config)

            // Multipart: 30 s without progress in any phase (connect, write,
            // read), but no 30 s cap on the whole upload — a multi-MB capture
            // over cellular legitimately takes longer than that.
            let uploadConfig = URLSessionConfiguration.default
            uploadConfig.httpCookieStorage = nil
            uploadConfig.urlCache = nil
            uploadConfig.timeoutIntervalForRequest = 30
            self.uploadSession = URLSession(configuration: uploadConfig)
        }

        let sseConfig = URLSessionConfiguration.default
        sseConfig.httpCookieStorage = nil
        sseConfig.urlCache = nil
        // 45s gap timer: matches the backend's presence-lease TTL, well past its 15s heartbeat
        sseConfig.timeoutIntervalForRequest = 45
        sseConfig.timeoutIntervalForResource = 300
        self.sseSession = URLSession(configuration: sseConfig)
    }

    public func setStaticHeaders(_ headers: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        self.staticHeaders = headers
    }

    // MARK: - NetworkClient

    public func execute(request: NetworkRequest) async throws -> NetworkResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        if let timeout = request.timeoutInterval {
            urlRequest.timeoutInterval = timeout
        }

        let assembledHeaders = assembleHeaders(for: request.headers)
        for (key, value) in assembledHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let body = request.body {
            urlRequest.httpBody = body
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        var responseHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                responseHeaders[k] = v
            }
        }

        return NetworkResponse(
            statusCode: httpResponse.statusCode,
            headers: responseHeaders,
            body: data,
            isSuccessful: (200...299).contains(httpResponse.statusCode)
        )
    }

    public func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        let boundary = "DigiaMultipart-\(UUID().uuidString)"
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = request.timeout

        var requestHeaders = request.headers
        requestHeaders["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        let assembledHeaders = assembleHeaders(for: requestHeaders)
        for (key, value) in assembledHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        var body = Data()
        // Append form fields
        for (name, value) in request.formFields {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        // Append files
        for file in request.files {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.fileName)\"\r\n".utf8))
            body.append(Data("Content-Type: \(file.mimeType)\r\n\r\n".utf8))
            body.append(file.data)
            body.append(Data("\r\n".utf8))
        }

        body.append(Data("--\(boundary)--\r\n".utf8))

        let (data, response) = try await uploadSession.upload(for: urlRequest, from: body)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        var responseHeaders: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                responseHeaders[k] = v
            }
        }

        return NetworkResponse(
            statusCode: httpResponse.statusCode,
            headers: responseHeaders,
            body: data,
            isSuccessful: (200...299).contains(httpResponse.statusCode)
        )
    }

    public func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = 45

        var requestHeaders = request.headers
        if requestHeaders["Accept"] == nil {
            requestHeaders["Accept"] = "text/event-stream"
        }
        if requestHeaders["Cache-Control"] == nil {
            requestHeaders["Cache-Control"] = "no-cache"
        }

        let assembledHeaders = assembleHeaders(for: requestHeaders)
        for (key, value) in assembledHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let body = request.body {
            urlRequest.httpBody = body
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        let subscription = URLSessionSseSubscription()
        let sseSession = self.sseSession

        subscription.task = Task { [weak handler] in
            // URLSession has no connect timeout separate from the 45 s gap, so
            // the response headers get their own 10 s deadline.
            let connectDeadline = Task {
                try await Task.sleep(nanoseconds: Self.sseConnectTimeoutNs)
                subscription.connectTimedOut()
            }
            do {
                let (bytes, response) = try await sseSession.bytes(for: urlRequest)
                connectDeadline.cancel()
                if Task.isCancelled || subscription.isCancelled { return }

                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    // A rejected stream never opened: an error carrying the
                    // status, not an open followed by a close.
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    handler?.onError(SseHTTPStatusError(statusCode: status))
                    return
                }

                handler?.onOpen()

                var parser = SSEFrameParser()
                for try await byte in bytes {
                    if Task.isCancelled || subscription.isCancelled {
                        bytes.task.cancel()
                        return
                    }
                    if let frame = parser.feed(byte) {
                        handler?.onEvent(SseEvent(id: frame.id, event: frame.event, data: frame.data))
                    }
                }

                if !subscription.isCancelled {
                    handler?.onClosed()
                }
            } catch {
                connectDeadline.cancel()
                if subscription.didTimeOutConnecting {
                    handler?.onError(URLError(.timedOut))
                } else if !Task.isCancelled && !subscription.isCancelled {
                    handler?.onError(error)
                }
            }
        }

        return subscription
    }

    private static let sseConnectTimeoutNs: UInt64 = 10_000_000_000

    // MARK: - Header Assembler

    public func assembleHeaders(for requestHeaders: [String: String]) -> [String: String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var headers: [String: String] = [
            "X-Digia-Platform": "ios",
            "x-digia-platform": "ios",
            "X-Digia-Device-Make": "Apple",
            "X-Digia-Os-Version": "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "X-Digia-Device-Model": Self.deviceModel(),
            "X-Digia-Sdk-Version": DigiaSdkVersion.value,
            "x-digia-sdk-version": DigiaSdkVersion.value,
            "X-Digia-Version": DigiaSdkVersion.value,
        ]

        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            headers["x-app-package-name"] = bundleId
        }
        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["x-app-version"] = appVersion
        }
        if let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
           !buildNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            headers["x-app-build-number"] = buildNumber
        }

        // Merge dynamic headers from provider if available
        if let provider = headerProvider {
            let provided = provider()
            for (key, value) in provided {
                headers[key] = value
            }
        }

        // Merge locked static headers if configured
        lock.lock()
        for (key, value) in staticHeaders {
            headers[key] = value
        }
        lock.unlock()

        // Merge caller-provided request headers on top
        for (key, value) in requestHeaders {
            headers[key] = value
        }

        // Canonical Duplication Rules:
        // 1. Project ID
        if let projectId = headers["X-Digia-Project-Id"] ?? headers["x-digia-project-id"] {
            headers["X-Digia-Project-Id"] = projectId
            headers["x-digia-project-id"] = projectId
        }

        // 2. Device ID
        if let deviceId = headers["X-Digia-Device-Id"] ?? headers["x-digia-device-id"] {
            headers["X-Digia-Device-Id"] = deviceId
            headers["x-digia-device-id"] = deviceId
        }

        // 3. SDK Version
        if let sdkVer = headers["X-Digia-Sdk-Version"] ?? headers["x-digia-sdk-version"] ?? headers["X-Digia-Version"] {
            headers["X-Digia-Sdk-Version"] = sdkVer
            headers["x-digia-sdk-version"] = sdkVer
            headers["X-Digia-Version"] = sdkVer
        }

        // 4. SDK Environment
        if let env = headers["X-Digia-Sdk-Environment"] ?? headers["X-Digia-Environment"] {
            headers["X-Digia-Sdk-Environment"] = env
            headers["X-Digia-Environment"] = env
        }

        // 5. Session ID
        if let sid = sessionIdProvider?() ?? headers["X-Digia-Session-Id"] ?? headers["x-digia-session-id"] {
            headers["X-Digia-Session-Id"] = sid
            headers["x-digia-session-id"] = sid
        }

        // Ensure Platform is strictly "ios"
        headers["X-Digia-Platform"] = "ios"
        headers["x-digia-platform"] = "ios"

        return headers
    }

    private static func deviceModel() -> String {
        var sysInfo = utsname()
        uname(&sysInfo)
        return withUnsafePointer(to: &sysInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

/// An SSE connect answered with a non-2xx status.
struct SseHTTPStatusError: Error, CustomStringConvertible {
    let statusCode: Int

    var description: String { "HTTP \(statusCode)" }
}

private final class URLSessionSseSubscription: CancellableSubscription, @unchecked Sendable {
    var task: Task<Void, Never>?
    private let lock = NSLock()
    private(set) var isCancelled = false
    private(set) var didTimeOutConnecting = false

    func cancel() {
        lock.lock()
        isCancelled = true
        task?.cancel()
        task = nil
        lock.unlock()
    }

    /// Abandons a connection whose response headers missed the deadline. Not
    /// a caller cancel: the handler still hears about it, as a timeout.
    func connectTimedOut() {
        lock.lock()
        didTimeOutConnecting = true
        task?.cancel()
        lock.unlock()
    }
}

/// Buffers raw SSE bytes into `(id, event, data)` frames on each blank-line boundary.
/// Not built on `bytes.lines` (`AsyncLineSequence`) — it silently drops blank
/// lines (`"a\n\nb"` yields `["a", "b"]`), so a parser waiting on `line.isEmpty` never fires.
///
/// Lines end at LF, CRLF or a bare CR. A line is decoded only once complete,
/// so a multi-byte character split across chunks is never broken. A field's
/// value loses exactly one leading space, as the SSE spec says.
struct SSEFrameParser {
    private var buffer = Data()
    private var lastWasCR = false
    private var eventName: String?
    private var eventId: String?
    private var dataLines: [String] = []

    /// Returns a completed frame once a blank-line boundary closes one, else `nil`.
    mutating func feed(_ byte: UInt8) -> (id: String?, event: String?, data: String)? {
        let cr = UInt8(ascii: "\r")
        let lf = UInt8(ascii: "\n")
        if byte == lf, lastWasCR {
            // The LF of a CRLF: the CR already ended the line.
            lastWasCR = false
            return nil
        }
        lastWasCR = byte == cr
        guard byte == lf || byte == cr else {
            buffer.append(byte)
            return nil
        }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return process(line)
    }

    private mutating func process(_ line: String) -> (id: String?, event: String?, data: String)? {
        if line.isEmpty {
            defer {
                eventName = nil
                eventId = nil
                dataLines = []
            }
            guard eventName != nil || eventId != nil || !dataLines.isEmpty else { return nil }
            return (eventId, eventName, dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil } // heartbeat comment
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        case "id": eventId = String(value)
        default: break
        }
        return nil
    }

    /// Convenience feed method for a slice or chunk of `Data`.
    mutating func feed(_ data: Data) -> [SseEvent] {
        var events: [SseEvent] = []
        for byte in data {
            if let frame = feed(byte) {
                events.append(SseEvent(id: frame.id, event: frame.event, data: frame.data))
            }
        }
        return events
    }
}

