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

/// Whether a slice of the requested range is served from disk or the network.
internal enum CacheActionKind: Sendable, Equatable {
    case local
    case remote
}

/// One contiguous slice of a read: serve it from the stored file or fetch it.
/// A nil `length` on a remote action means "to end of resource" (open Range).
internal struct CacheAction: Sendable, Equatable {
    internal var kind: CacheActionKind
    internal var offset: Int64
    internal var length: Int64?

    internal init(kind: CacheActionKind, offset: Int64, length: Int64?) {
        self.kind = kind
        self.offset = offset
        self.length = length
    }
}

/// Splits a requested range into stored (local) and missing (remote) actions.
/// `fragments` are the stored byte ranges; unsorted input is tolerated.
/// A nil `requestedLength` means "to end of resource" when the total is unknown.
internal func planCacheActions(
    requestedOffset: Int64,
    requestedLength: Int64?,
    fragments: [Range<Int64>]
) -> [CacheAction] {
    let start = max(0, requestedOffset)
    if let requestedLength {
        guard requestedLength > 0 else { return [] }
        let end = start + requestedLength
        return planBoundedActions(start: start, end: end, fragments: fragments)
    }
    var actions: [CacheAction] = []
    var cursor = start
    for fragment in fragments.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if fragment.lowerBound > cursor {
            break
        }
        if fragment.upperBound > cursor {
            actions.append(CacheAction(kind: .local, offset: cursor, length: fragment.upperBound - cursor))
            cursor = fragment.upperBound
        }
    }
    actions.append(CacheAction(kind: .remote, offset: cursor, length: nil))
    return actions
}

private func planBoundedActions(
    start: Int64,
    end: Int64,
    fragments: [Range<Int64>]
) -> [CacheAction] {
    guard end > start else { return [] }
    var actions: [CacheAction] = []
    var cursor = start
    for fragment in fragments.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if fragment.lowerBound >= end {
            break
        }
        if fragment.upperBound <= cursor {
            continue
        }
        if fragment.lowerBound > cursor {
            actions.append(CacheAction(kind: .remote, offset: cursor, length: fragment.lowerBound - cursor))
            cursor = fragment.lowerBound
        }
        let coveredEnd = min(fragment.upperBound, end)
        if coveredEnd > cursor {
            actions.append(CacheAction(kind: .local, offset: cursor, length: coveredEnd - cursor))
            cursor = coveredEnd
        }
    }
    if cursor < end {
        actions.append(CacheAction(kind: .remote, offset: cursor, length: end - cursor))
    }
    return actions
}
