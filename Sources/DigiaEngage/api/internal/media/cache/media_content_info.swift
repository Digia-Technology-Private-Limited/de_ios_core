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
import UniformTypeIdentifiers

/// Playback metadata for one cached URL: the UTI AVFoundation expects, the total
/// byte length when known, and whether the server honours HTTP Range requests.
/// A negative `contentLength` means the total length is unknown.
internal struct MediaContentInfo: Codable, Sendable, Equatable {
    internal static let unknownLength: Int64 = -1

    internal var contentType: String
    internal var contentLength: Int64
    internal var byteRangeAccessSupported: Bool

    internal init(
        contentType: String,
        contentLength: Int64 = MediaContentInfo.unknownLength,
        byteRangeAccessSupported: Bool = false
    ) {
        self.contentType = contentType
        self.contentLength = contentLength
        self.byteRangeAccessSupported = byteRangeAccessSupported
    }

    internal var hasKnownLength: Bool {
        contentLength >= 0
    }
}

/// Maps an HTTP MIME type to the UTI string AVFoundation expects in
/// `contentInformationRequest.contentType`. Unknown or missing types degrade to
/// generic data rather than failing the load.
internal func mediaCacheUTI(forMimeType mimeType: String?) -> String {
    guard let mimeType, let type = UTType(mimeType: mimeType) else {
        return UTType.data.identifier
    }
    return type.identifier
}

/// Gate for what the cache will store. Video and audio are the point of the
/// cache; `application/*` covers MP4s served as `application/octet-stream`.
/// A missing MIME type is allowed: never break playback for metadata reasons.
internal func isCacheable(mimeType: String?) -> Bool {
    guard let mimeType else { return true }
    let lower = mimeType.lowercased()
    return lower.hasPrefix("video/") || lower.hasPrefix("audio/") || lower.hasPrefix("application/")
}
