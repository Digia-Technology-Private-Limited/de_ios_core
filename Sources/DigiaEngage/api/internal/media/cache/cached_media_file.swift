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

/// The stored bytes plus index for one URL. Confined to
/// `MediaRangeCacheStore`'s isolation: every method runs on the store actor, so
/// all file I/O stays off the main thread without extra locking.
internal final class CachedMediaFile {
    internal let dataURL: URL
    internal private(set) var index: RangeIndexStore
    private var handle: FileHandle?

    internal init(dataURL: URL) {
        self.dataURL = dataURL
        self.index = RangeIndexPersistence.load(dataURL: dataURL) ?? RangeIndexStore()
    }

    /// Highest stored byte offset. Authoritative for capacity checks: the index
    /// is updated on every write, so this never needs a stat call.
    internal var maxStoredEnd: Int64 {
        index.fragments.map(\.end).max() ?? 0
    }

    private func ensureHandle() throws -> FileHandle {
        if let handle {
            return handle
        }
        if !FileManager.default.fileExists(atPath: dataURL.path) {
            FileManager.default.createFile(atPath: dataURL.path, contents: nil)
        }
        let opened = try FileHandle(forUpdating: dataURL)
        handle = opened
        return opened
    }

    /// Bounds-checked read. Returns nil on any I/O failure (the caller drops
    /// the overlapping fragments and re-fetches) and short data at EOF. Never
    /// throws: a truncated file degrades to a re-fetch, never a render failure.
    internal func read(offset: Int64, length: Int64) -> Data? {
        assert(!Thread.isMainThread)
        guard offset >= 0 else { return nil }
        guard length > 0 else { return Data() }
        do {
            let file = try ensureHandle()
            try file.seek(toOffset: UInt64(offset))
            return try file.read(upToCount: Int(length))
        } catch {
            return nil
        }
    }

    /// Reads everything from `offset` to end of file for open-ended requests.
    internal func readToEnd(from offset: Int64) -> Data? {
        assert(!Thread.isMainThread)
        guard offset >= 0 else { return nil }
        do {
            let file = try ensureHandle()
            try file.seek(toOffset: UInt64(offset))
            return try file.readToEnd()
        } catch {
            return nil
        }
    }

    internal func write(_ data: Data, at offset: Int64) throws {
        assert(!Thread.isMainThread)
        guard !data.isEmpty, offset >= 0 else { return }
        let file = try ensureHandle()
        try file.seek(toOffset: UInt64(offset))
        try file.write(contentsOf: data)
        index.addFragment(offset: offset, length: Int64(data.count))
    }

    /// Drops index ranges the file no longer holds (short read at a stored
    /// offset). The uncovered bytes are re-fetched on the next pass.
    internal func removeFragments(overlapping range: Range<Int64>) {
        index.removeFragments(overlapping: range)
    }

    /// Records playback metadata. Unlike VIMediaCache's `setContentInfo`, this
    /// never truncates the file: stored bytes are kept even if the server later
    /// reports a shorter length. First info wins; an unknown length is upgraded
    /// when the real total arrives.
    internal func updateContentInfo(_ info: MediaContentInfo) {
        if index.contentInfo == nil {
            index.contentInfo = info
        } else if index.contentInfo?.hasKnownLength == false, info.hasKnownLength {
            index.contentInfo = info
        }
    }

    internal func persist() {
        assert(!Thread.isMainThread)
        try? handle?.synchronize()
        RangeIndexPersistence.save(index, dataURL: dataURL)
    }

    internal func close() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }

    deinit {
        try? handle?.close()
    }
}
