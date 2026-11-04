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

import AVFoundation
import Foundation

/// The slice of AVAssetResourceLoadingRequest the cache needs, behind a
/// protocol so the worker is unit-testable with a fake. Conforms to Sendable:
/// implementations are confined to one serial queue (production) or locked
/// (tests), and AVAssetResourceLoadingRequest calls are thread-safe for this
/// streaming use.
internal protocol MediaLoadingRequest: AnyObject, Sendable {
    var requestedOffset: Int64 { get }
    var requestedLength: Int { get }
    var requestsAllDataToEnd: Bool { get }
    /// Stable identity for loader bookkeeping: the wrapped AVAsset request in
    /// production, the fake itself in tests.
    var requestID: AnyObject { get }
    func fillContentInfo(contentType: String?, contentLength: Int64, byteRangeSupported: Bool)
    func respond(with data: Data)
    func finish(error: NSError?)
}

/// Production adapter over AVAssetResourceLoadingRequest. Exactly one of
/// `finishLoading` / `finishLoading(with:)` runs per request: a second finish
/// (cancel racing completion) is dropped, so every loading request is finished
/// or cancelled exactly once.
internal final class AVAssetLoadingRequestAdapter: MediaLoadingRequest, @unchecked Sendable {
    private let request: AVAssetResourceLoadingRequest
    private let lock = NSLock()
    private var finished = false

    internal init(_ request: AVAssetResourceLoadingRequest) {
        self.request = request
    }

    internal var requestID: AnyObject {
        request
    }

    internal var requestedOffset: Int64 {
        guard let dataRequest = request.dataRequest else { return 0 }
        return dataRequest.currentOffset != 0 ? dataRequest.currentOffset : dataRequest.requestedOffset
    }

    internal var requestedLength: Int {
        request.dataRequest?.requestedLength ?? 0
    }

    internal var requestsAllDataToEnd: Bool {
        request.dataRequest?.requestsAllDataToEndOfResource ?? false
    }

    internal func fillContentInfo(contentType: String?, contentLength: Int64, byteRangeSupported: Bool) {
        guard let contentInformationRequest = request.contentInformationRequest else { return }
        if let contentType {
            contentInformationRequest.contentType = contentType
        }
        if contentLength >= 0 {
            contentInformationRequest.contentLength = contentLength
        }
        contentInformationRequest.isByteRangeAccessSupported = byteRangeSupported
    }

    internal func respond(with data: Data) {
        request.dataRequest?.respond(with: data)
    }

    internal func finish(error: NSError?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let error {
            request.finishLoading(with: error)
        } else {
            request.finishLoading()
        }
    }
}

/// Serves one loading request through the range store: fills the content
/// information, streams the requested bytes, and finishes exactly once.
/// Cancellation cancels the in-flight fetch and finishes the request as
/// cancelled, so no request ever hangs.
internal final class LoadingRequestWorker {
    private let store: MediaRangeCacheStore
    private let url: URL
    private let request: any MediaLoadingRequest
    private var task: Task<Void, Never>?
    internal var onDone: (@Sendable () -> Void)?

    internal init(store: MediaRangeCacheStore, url: URL, request: any MediaLoadingRequest) {
        self.store = store
        self.url = url
        self.request = request
    }

    @discardableResult
    internal func start() -> Task<Void, Never> {
        let store = self.store
        let url = self.url
        let request = self.request
        let done = onDone
        let task = Task<Void, Never> {
            defer { done?() }
            if let info = await store.contentInfo(for: url) {
                request.fillContentInfo(
                    contentType: info.contentType,
                    contentLength: info.contentLength,
                    byteRangeSupported: info.byteRangeAccessSupported
                )
            }
            // requestsAllDataToEndOfResource with an unknown total is an
            // open-ended fetch; clamp to a bounded range only when the total is
            // known, guarding against offset >= total (no underflow).
            let offset = request.requestedOffset
            var length: Int? = request.requestedLength > 0 ? request.requestedLength : nil
            if request.requestsAllDataToEnd {
                if let total = await store.contentInfo(for: url)?.contentLength, total >= 0 {
                    length = offset < total ? Int(total - offset) : 0
                } else {
                    length = nil
                }
            }
            do {
                try await store.serve(
                    url: url,
                    offset: offset,
                    length: length,
                    onResponse: { info in
                        request.fillContentInfo(
                            contentType: info.contentType,
                            contentLength: info.contentLength,
                            byteRangeSupported: info.byteRangeAccessSupported
                        )
                    },
                    onData: { request.respond(with: $0) }
                )
                request.finish(error: nil)
            } catch {
                request.finish(error: LoadingRequestWorker.finishingError(error))
            }
        }
        self.task = task
        return task
    }

    internal func cancel() {
        task?.cancel()
        task = nil
        request.finish(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil))
    }

    internal static func finishingError(_ error: any Error) -> NSError {
        if error is CancellationError {
            return NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: nil)
        }
        return error as NSError
    }
}
