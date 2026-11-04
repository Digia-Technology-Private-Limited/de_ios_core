import DigiaMediaCache
import Foundation

/// Shared fake for the core's video/prefetch tests after the cache contract suite moved to
/// `de_ios_media_cache`. The production seam remains the package's public `RangeFetchClient`.
internal final actor FakeRangeFetchClient: RangeFetchClient {
    internal struct Behavior: Sendable {
        var body: Data
        var contentType: String?
        var totalLength: Int64?
        var rangeSupported: Bool
    }

    private var behaviors: [String: Behavior] = [:]
    private var calls: [(url: URL, range: Range<Int64>?)] = []
    private var delayNanoseconds: UInt64 = 0
    private var failAllCalls = false
    private var observedCancellation = false

    internal func setBehavior(
        url: URL,
        body: Data,
        contentType: String? = "video/mp4",
        totalLength: Int64? = nil,
        rangeSupported: Bool = true
    ) {
        behaviors[url.absoluteString] = Behavior(
            body: body,
            contentType: contentType,
            totalLength: totalLength,
            rangeSupported: rangeSupported
        )
    }

    internal func setDelay(_ nanoseconds: UInt64) { delayNanoseconds = nanoseconds }
    internal func enableFailAllCalls() { failAllCalls = true }
    internal func callCount() -> Int { calls.count }
    internal func recordedRanges() -> [Range<Int64>?] { calls.map(\.range) }
    internal func didObserveCancellation() -> Bool { observedCancellation }

    internal func fetch(url: URL, range: Range<Int64>?) async throws -> RangeFetchResponse {
        calls.append((url, range))
        if failAllCalls { throw URLError(.cannotLoadFromNetwork) }
        if delayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                observedCancellation = true
                throw error
            }
        }
        try Task.checkCancellation()
        guard let behavior = behaviors[url.absoluteString] else {
            throw URLError(.fileDoesNotExist)
        }
        let total = behavior.totalLength ?? Int64(behavior.body.count)
        if !behavior.rangeSupported {
            let body = behavior.body
            return RangeFetchResponse(
                contentType: behavior.contentType,
                totalLength: total,
                rangeSupported: false,
                chunks: AsyncThrowingStream { continuation in
                    continuation.yield(body)
                    continuation.finish()
                }
            )
        }
        let slice: Data
        if let range {
            let lower = min(Int(range.lowerBound), behavior.body.count)
            let upper = range.upperBound == Int64.max
                ? behavior.body.count
                : min(Int(range.upperBound), behavior.body.count)
            slice = lower < upper ? behavior.body.subdata(in: lower ..< upper) : Data()
        } else {
            slice = behavior.body
        }
        return RangeFetchResponse(
            contentType: behavior.contentType,
            totalLength: total,
            rangeSupported: true,
            chunks: AsyncThrowingStream { continuation in
                if !slice.isEmpty { continuation.yield(slice) }
                continuation.finish()
            }
        )
    }
}
