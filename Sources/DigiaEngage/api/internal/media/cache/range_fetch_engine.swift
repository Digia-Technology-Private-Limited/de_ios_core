// Derived from VIMediaCache (MIT), Copyright (c) 2016 Vito Zhang <vvitozhang@gmail.com>.
//
// The MIT License (MIT)
// Copyright (c) 2016 Vito Zhang <vvitozhang@gmail.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation

/// Extracts the total length from a `Content-Range` header value such as
/// `bytes 0-99/1234` (or `bytes */1234` for 416 responses). Nil when unknown.
internal func parseTotalLength(fromContentRange value: String?) -> Int64? {
    guard let value, let slash = value.lastIndex(of: "/") else { return nil }
    let total = value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces)
    guard total != "*" else { return nil }
    return Int64(total)
}

/// One network fetch: response metadata plus the body as a throwing stream so
/// playback can start while bytes are still arriving. A `rangeSupported` false
/// value means the server ignored the Range header and sent the whole body.
internal struct RangeFetchResponse: Sendable {
    internal var contentType: String?
    internal var totalLength: Int64?
    internal var rangeSupported: Bool
    internal var chunks: AsyncThrowingStream<Data, any Error>

    internal init(
        contentType: String?,
        totalLength: Int64?,
        rangeSupported: Bool,
        chunks: AsyncThrowingStream<Data, any Error>
    ) {
        self.contentType = contentType
        self.totalLength = totalLength
        self.rangeSupported = rangeSupported
        self.chunks = chunks
    }
}

/// Injectable fetch layer for the range cache. Production uses
/// `URLSessionRangeFetchClient`; tests substitute a fake.
internal protocol RangeFetchClient: Sendable {
    /// Fetches `range` (nil = whole resource, upperBound `.max` = open-ended).
    func fetch(url: URL, range: Range<Int64>?) async throws -> RangeFetchResponse
}

private final class FetchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var producer: Task<Void, Never>?
    private var sessionTask: URLSessionTask?

    func set(producer: Task<Void, Never>?, sessionTask: URLSessionTask?) {
        lock.lock()
        defer { lock.unlock() }
        self.producer = producer
        self.sessionTask = sessionTask
    }

    func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        producer?.cancel()
        sessionTask?.cancel()
    }
}

/// Default `RangeFetchClient` over `URLSession`. Cancelling the caller's task
/// cancels the underlying URLSession task.
internal final class URLSessionRangeFetchClient: RangeFetchClient, @unchecked Sendable {
    private let session: URLSession

    internal init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    internal func fetch(url: URL, range: Range<Int64>?) async throws -> RangeFetchResponse {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let range {
            if range.upperBound == Int64.max {
                request.setValue("bytes=\(range.lowerBound)-", forHTTPHeaderField: "Range")
            } else {
                request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            }
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
        let mimeType = http.mimeType
        guard isCacheable(mimeType: mimeType) else {
            bytes.task.cancel()
            throw URLError(.unsupportedURL)
        }
        switch http.statusCode {
        case 206:
            let total = parseTotalLength(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
            return streamResponse(
                bytes: bytes,
                contentType: mimeType,
                totalLength: total,
                rangeSupported: true
            )
        case 200:
            let totalLength = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
            return streamResponse(
                bytes: bytes,
                contentType: mimeType,
                totalLength: totalLength,
                rangeSupported: range == nil
            )
        case 416:
            bytes.task.cancel()
            let total = parseTotalLength(fromContentRange: http.value(forHTTPHeaderField: "Content-Range"))
            return RangeFetchResponse(
                contentType: mimeType,
                totalLength: total,
                rangeSupported: true,
                chunks: AsyncThrowingStream { $0.finish() }
            )
        default:
            bytes.task.cancel()
            throw URLError(.badServerResponse)
        }
    }

    private func streamResponse(
        bytes: URLSession.AsyncBytes,
        contentType: String?,
        totalLength: Int64?,
        rangeSupported: Bool
    ) -> RangeFetchResponse {
        let sessionTask = bytes.task
        let cancellation = FetchCancellation()
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(of: Data.self)
        continuation.onTermination = { _ in cancellation.cancelAll() }
        let producer = Task<Void, Never> {
            do {
                var batch = Data()
                batch.reserveCapacity(64 * 1_024)
                for try await byte in bytes {
                    batch.append(byte)
                    if batch.count >= 64 * 1_024 {
                        continuation.yield(batch)
                        batch = Data()
                        batch.reserveCapacity(64 * 1_024)
                    }
                }
                if !batch.isEmpty {
                    continuation.yield(batch)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        cancellation.set(producer: producer, sessionTask: sessionTask)
        return RangeFetchResponse(
            contentType: contentType,
            totalLength: totalLength,
            rangeSupported: rangeSupported,
            chunks: stream
        )
    }
}
