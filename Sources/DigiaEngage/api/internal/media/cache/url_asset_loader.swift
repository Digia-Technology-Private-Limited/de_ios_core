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

/// One loader per origin URL: owns the workers for its in-flight loading
/// requests. All methods run on `MediaResourceLoader`'s delegate queue in
/// production (tests drive it serially), so no locking is needed. Workers
/// remove themselves on completion; the loader reports idle so the manager can
/// drop it instead of leaking finished requests.
internal final class URLAssetLoader {
    internal let url: URL
    private let store: MediaRangeCacheStore
    private let queue: DispatchQueue
    private var workers: [ObjectIdentifier: LoadingRequestWorker] = [:]
    internal var onIdle: (() -> Void)?

    private final class WeakLoader: @unchecked Sendable {
        weak var loader: URLAssetLoader?
    }

    internal init(url: URL, store: MediaRangeCacheStore, queue: DispatchQueue) {
        self.url = url
        self.store = store
        self.queue = queue
    }

    internal var isIdle: Bool {
        workers.isEmpty
    }

    /// Starts serving `request`. Returns the worker task (tests await it).
    @discardableResult
    internal func add(_ request: any MediaLoadingRequest) -> Task<Void, Never> {
        let worker = LoadingRequestWorker(store: store, url: url, request: request)
        let id = ObjectIdentifier(request.requestID)
        let queue = self.queue
        let box = WeakLoader()
        box.loader = self
        worker.onDone = {
            queue.async {
                box.loader?.drop(id: id)
            }
        }
        workers[id] = worker
        return worker.start()
    }

    /// Cancels the worker for `request` and finishes the request as cancelled.
    /// Unknown requests are ignored.
    internal func remove(_ request: any MediaLoadingRequest) {
        let id = ObjectIdentifier(request.requestID)
        guard let worker = workers[id] else { return }
        workers[id] = nil
        worker.onDone = nil
        worker.cancel()
        notifyIfIdle()
    }

    internal func cancelAll() {
        let pending = workers
        workers.removeAll()
        for worker in pending.values {
            worker.onDone = nil
            worker.cancel()
        }
        notifyIfIdle()
    }

    private func drop(id: ObjectIdentifier) {
        workers[id] = nil
        notifyIfIdle()
    }

    private func notifyIfIdle() {
        if workers.isEmpty {
            onIdle?()
        }
    }
}
