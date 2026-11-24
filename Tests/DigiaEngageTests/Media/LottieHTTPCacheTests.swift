import Foundation
import Network
import Testing
@testable import DigiaEngage

@Suite("Lottie HTTP cache", .tags(.integration, .media))
struct LottieHTTPCacheTests {
    // Fails if media_load_health.swift sets requestCachePolicy to .reloadIgnoringLocalCacheData
    // or reduces diskCapacity to 100 MiB (the 6 MiB reply no longer fits the per-response limit).
    // Restoring Lottie's parsed cache makes the second no-store load skip the origin.
    @Test("remote Lottie obeys HTTP freshness, storage and revalidation")
    func httpCache() async throws {
        let origin = try LottieHTTPOrigin()
        defer { origin.stop() }
        let port = try await origin.start()
        let base = try #require(URL(string: "http://127.0.0.1:\(port)/\(UUID().uuidString)/"))

        for name in ["fresh", "no-store", "etag", "expires", "last-modified"] {
            let url = base.appendingPathComponent("\(name).json")
            try #require(await loadLottieSource(url).source != nil, "Initial load: \(name)")
            #expect(await loadLottieSource(url).source != nil, "Second load: \(name)")
        }

        #expect(origin.requests(for: "fresh").count == 1)
        #expect(origin.requests(for: "expires").count == 1)
        let noStore = origin.requests(for: "no-store")
        #expect(noStore.count == 2)
        #expect(noStore.allSatisfy { !$0.contains("if-none-match:") })
        let etag = origin.requests(for: "etag")
        #expect(etag.count == 2)
        #expect(etag.last?.contains("if-none-match: \(LottieHTTPOrigin.etag)") == true)
        let lastModified = origin.requests(for: "last-modified")
        #expect(lastModified.count == 2)
        #expect(lastModified.last?.contains("if-modified-since: \(LottieHTTPOrigin.lastModified.lowercased())") == true)
    }
}

/// A real HTTP origin leaves storage and conditional requests to URLSession's HTTP protocol.
private final class LottieHTTPOrigin: @unchecked Sendable {
    static let etag = #""animation-v1""#
    static let lastModified = "Wed, 01 Jan 2020 00:00:00 GMT"
    private static let animation = Data(#"{"v":"5.7.4","fr":30,"ip":0,"op":30,"w":100,"h":100,"nm":"t","ddd":0,"assets":[],"layers":[]}"#.utf8)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "lottie-http-origin")
    private let lock = NSLock()
    private var history: [String: [String]] = [:]

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> UInt16 {
        let ports = AsyncThrowingStream<UInt16, Error> { continuation in
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    if let port = listener?.port { continuation.yield(port.rawValue) }
                    continuation.finish()
                case .failed(let error):
                    continuation.finish(throwing: error)
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
        var iterator = ports.makeAsyncIterator()
        return try #require(try await iterator.next())
    }

    func stop() { listener.cancel() }

    func requests(for name: String) -> [String] { lock.withLock { history[name, default: []] } }

    private func receive(on connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            let bytes = buffered + (data ?? Data())
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil {
                respond(to: String(decoding: bytes, as: UTF8.self).lowercased(), on: connection)
            } else if !complete, error == nil, bytes.count < 8192 {
                receive(on: connection, buffered: bytes)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let path = request.split(separator: " ").dropFirst().first ?? ""
        let name = URL(fileURLWithPath: String(path)).deletingPathExtension().lastPathComponent
        lock.withLock { history[name, default: []].append(request) }

        var body = Self.animation
        var headers = ""
        var notModified = false
        switch name {
        case "fresh":
            headers = "Cache-Control: max-age=3600\r\n"
            body.append(Data(repeating: 0x20, count: 6 * 1024 * 1024 - body.count))
        case "no-store":
            headers = "Cache-Control: no-store, max-age=3600\r\nETag: \(Self.etag)\r\n"
        case "etag":
            headers = "Cache-Control: no-cache\r\nETag: \(Self.etag)\r\n"
            notModified = request.contains("if-none-match: \(Self.etag)")
        case "expires":
            headers = "Expires: \(Self.httpDate(Date().addingTimeInterval(3600)))\r\n"
        case "last-modified":
            headers = "Cache-Control: max-age=0\r\nLast-Modified: \(Self.lastModified)\r\n"
            notModified = request.contains("if-modified-since: \(Self.lastModified.lowercased())")
        default:
            break
        }

        let status = notModified ? "304 Not Modified" : "200 OK"
        let length = notModified ? "" : "Content-Length: \(body.count)\r\n"
        var response = Data((
            "HTTP/1.1 \(status)\r\nDate: \(Self.httpDate(Date()))\r\n"
            + "Connection: close\r\nContent-Type: application/json\r\n\(headers)\(length)\r\n"
        ).utf8)
        if !notModified { response.append(body) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
