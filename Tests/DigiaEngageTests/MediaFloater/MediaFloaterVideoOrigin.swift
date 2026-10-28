import Foundation

/// A scripted origin for story videos, the iOS counterpart of `MediaOrigin` in
/// `flutter/core/test/fixture_behaviour/support/story_video_cache_support.dart`.
///
/// Flutter serves the videos from a loopback HTTP server; here the cache under test is given a
/// `URLSession` whose only protocol is ``MediaFloaterVideoProtocol``, so `DigiaVideoFileCache`'s own
/// downloader, partial-file writer, publisher and eviction run for real and only the network is
/// scripted. Each origin owns one host name, so origins of different tests never see each other's
/// requests.
final class MediaFloaterVideoOrigin: @unchecked Sendable {

    /// How the origin answers one path.
    enum Reply {
        /// `200` with the body and a matching `Content-Length`.
        case body(Data)
        /// The given status with a short text body, as an error page.
        case status(Int)
        /// `200` announcing `announced` bytes, then only `sent` of them before the response ends.
        case breakOff(announced: Int, sent: Int)
        /// `200` announcing `announced` bytes and then no body; gives up after two seconds unless
        /// the client hung up first.
        case announceOnly(announced: Int)
    }

    let host = "\(UUID().uuidString.lowercased()).origin.test"
    let session: URLSession

    private let lock = NSLock()
    private var replies: [String: Reply] = [:]
    private var defaultBody = Data(repeating: 0x5A, count: 2_048)
    private var _requests: [String] = []
    private var _hungUp: [String] = []
    private var held: [String: () -> Void] = [:]
    private var _holdAll = false

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaFloaterVideoProtocol.self]
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        MediaFloaterVideoProtocol.register(self)
    }

    deinit { MediaFloaterVideoProtocol.unregister(host) }

    /// The URL of [path] on this origin, e.g. `url("/movie.mp4")`.
    func url(_ path: String) -> URL { URL(string: "https://\(host)\(path)")! }

    func reply(_ path: String, with reply: Reply) { lock.withLock { replies[path] = reply } }

    /// Whether each new request waits for ``release(_:)`` before it is answered.
    var holdAll: Bool {
        get { lock.withLock { _holdAll } }
        set { lock.withLock { _holdAll = newValue } }
    }

    /// Every request, by path, in arrival order.
    var requests: [String] { lock.withLock { _requests } }

    /// Paths whose transfer the client cancelled before the origin finished it.
    var hungUp: [String] { lock.withLock { _hungUp } }

    func release(_ path: String) {
        let answer = lock.withLock { held.removeValue(forKey: path) }
        answer?()
    }

    func releaseAll() {
        let answers = lock.withLock { () -> [() -> Void] in
            defer { held.removeAll() }
            return Array(held.values)
        }
        answers.forEach { $0() }
    }

    // MARK: - Called by the protocol

    fileprivate func received(_ path: String, answer: @escaping () -> Void) {
        let hold = lock.withLock { () -> Bool in
            _requests.append(path)
            if _holdAll { held[path] = answer }
            return _holdAll
        }
        if !hold { answer() }
    }

    fileprivate func replyFor(_ path: String) -> Reply {
        lock.withLock { replies[path] ?? .body(defaultBody) }
    }

    fileprivate func clientHungUp(_ path: String) { lock.withLock { _hungUp.append(path) } }
}

/// The protocol a ``MediaFloaterVideoOrigin``'s session loads through. Every client callback is
/// made on the thread `startLoading` ran on, as `URLProtocol` requires.
final class MediaFloaterVideoProtocol: URLProtocol, @unchecked Sendable {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var origins: [String: WeakOrigin] = [:]

    private struct WeakOrigin { weak var origin: MediaFloaterVideoOrigin? }

    static func register(_ origin: MediaFloaterVideoOrigin) {
        lock.withLock { origins[origin.host] = WeakOrigin(origin: origin) }
    }

    static func unregister(_ host: String) {
        _ = lock.withLock { origins.removeValue(forKey: host) }
    }

    private static func origin(for request: URLRequest) -> MediaFloaterVideoOrigin? {
        guard let host = request.url?.host else { return nil }
        return lock.withLock { origins[host]?.origin }
    }

    override class func canInit(with request: URLRequest) -> Bool { origin(for: request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stateLock = NSLock()
    private var thread: Thread?
    private var finished = false
    private var pending: [() -> Void] = []

    override func startLoading() {
        thread = Thread.current
        guard let origin = Self.origin(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let path = url.path
        origin.received(path) { [weak self] in
            self?.onLoadingThread { self?.answer(origin.replyFor(path), url: url) }
        }
    }

    override func stopLoading() {
        let wasFinished = stateLock.withLock { () -> Bool in
            defer { finished = true }
            return finished
        }
        if !wasFinished, let url = request.url {
            Self.origin(for: request)?.clientHungUp(url.path)
        }
    }

    private var isFinished: Bool { stateLock.withLock { finished } }

    private func markFinished() { stateLock.withLock { finished = true } }

    private func answer(_ reply: MediaFloaterVideoOrigin.Reply, url: URL) {
        guard !isFinished, let client else { return }
        switch reply {
        case let .body(data):
            client.urlProtocol(self, didReceive: response(url, 200, length: data.count), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: data)
            markFinished()
            client.urlProtocolDidFinishLoading(self)
        case let .status(code):
            let page = Data("<html>error \(code)</html>".utf8)
            client.urlProtocol(self, didReceive: response(url, code, length: page.count), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: page)
            markFinished()
            client.urlProtocolDidFinishLoading(self)
        case let .breakOff(announced, sent):
            client.urlProtocol(self, didReceive: response(url, 200, length: announced), cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(repeating: 0, count: sent))
            markFinished()
            client.urlProtocolDidFinishLoading(self)
        case let .announceOnly(announced):
            client.urlProtocol(self, didReceive: response(url, 200, length: announced), cacheStoragePolicy: .notAllowed)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.onLoadingThread {
                    guard let self, !self.isFinished else { return }
                    self.markFinished()
                    self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                }
            }
        }
    }

    private func response(_ url: URL, _ status: Int, length: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(length)", "Content-Type": "video/mp4"])!
    }

    // MARK: - Thread hop

    private func onLoadingThread(_ work: @escaping () -> Void) {
        guard let thread else { return work() }
        stateLock.withLock { pending.append(work) }
        perform(#selector(runPending), on: thread, with: nil, waitUntilDone: false)
    }

    @objc private func runPending() {
        let work = stateLock.withLock { () -> [() -> Void] in
            defer { pending.removeAll() }
            return pending
        }
        work.forEach { $0() }
    }
}
