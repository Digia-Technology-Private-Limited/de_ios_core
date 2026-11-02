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

/// AVAssetResourceLoaderDelegate that routes playback through the range cache.
/// Origin URLs are wrapped in the private `digia-media-cache` scheme (never
/// touching the network, so no ATS exception is needed); the delegate runs on
/// its own serial queue, never the main thread.
internal final class MediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    internal static let scheme = "digia-media-cache"

    /// Wraps an origin URL in the private cache scheme. Nil when the origin
    /// cannot be represented (the caller then loads it directly, uncached).
    internal static func assetURL(for url: URL) -> URL? {
        URL(string: scheme + "://" + url.absoluteString)
    }

    /// Recovers the origin URL from a wrapped asset URL. Nil for foreign URLs.
    internal static func originURL(from assetURL: URL) -> URL? {
        guard assetURL.scheme == scheme else { return nil }
        let prefix = scheme + "://"
        let absolute = assetURL.absoluteString
        guard absolute.hasPrefix(prefix) else { return nil }
        return URL(string: String(absolute.dropFirst(prefix.count)))
    }

    private let store: MediaRangeCacheStore
    private let delegateQueue = DispatchQueue(label: "tech.digia.engage.media.cache", qos: .userInitiated)
    /// Confined to `delegateQueue`.
    private var loaders: [String: URLAssetLoader] = [:]

    internal init(store: MediaRangeCacheStore? = nil) {
        self.store = store ?? MediaRangeCacheStore.shared()
        super.init()
    }

    /// Builds a player item that reads through the range cache.
    internal func playerItem(for url: URL) -> AVPlayerItem? {
        guard let assetURL = Self.assetURL(for: url) else { return nil }
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
        return AVPlayerItem(asset: asset)
    }

    internal func cancelAll() {
        delegateQueue.async { [weak self] in
            guard let self else { return }
            for loader in self.loaders.values {
                loader.cancelAll()
            }
            self.loaders.removeAll()
        }
    }

    // MARK: - AVAssetResourceLoaderDelegate (all on delegateQueue)

    internal func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
            let origin = Self.originURL(from: requestURL)
        else {
            return false
        }
        let key = requestURL.absoluteString
        let loader: URLAssetLoader
        if let existing = loaders[key] {
            loader = existing
        } else {
            loader = URLAssetLoader(url: origin, store: store, queue: delegateQueue)
            loader.onIdle = { [weak self, weak loader] in
                guard let self, let loader else { return }
                self.delegateQueue.async { [weak self] in
                    guard let self else { return }
                    if loader.isIdle {
                        self.loaders[key] = nil
                    }
                }
            }
            loaders[key] = loader
        }
        loader.add(AVAssetLoadingRequestAdapter(loadingRequest))
        return true
    }

    internal func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let requestURL = loadingRequest.request.url else { return }
        loaders[requestURL.absoluteString]?.remove(AVAssetLoadingRequestAdapter(loadingRequest))
    }
}
