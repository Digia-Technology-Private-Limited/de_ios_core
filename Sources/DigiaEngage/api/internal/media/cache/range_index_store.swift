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

/// One stored byte range. Codable so the index survives relaunch.
internal struct RangeFragment: Codable, Sendable, Equatable {
    internal var offset: Int64
    internal var length: Int64

    internal init(offset: Int64, length: Int64) {
        self.offset = offset
        self.length = length
    }

    internal var end: Int64 {
        offset + length
    }

    internal var range: Range<Int64> {
        offset ..< end
    }
}

/// The persisted index for one cached URL: playback metadata plus the stored
/// byte ranges. Partial entries are valid: any subset of ranges may be stored.
internal struct RangeIndexStore: Codable, Sendable {
    internal static let currentVersion = 1

    internal var version: Int = RangeIndexStore.currentVersion
    internal var contentInfo: MediaContentInfo?
    internal var fragments: [RangeFragment] = []

    internal var downloadedBytes: Int64 {
        fragments.reduce(0) { $0 + $1.length }
    }

    internal var storedRanges: [Range<Int64>] {
        fragments.map(\.range)
    }

    /// Records newly stored bytes, merging overlapping or adjacent fragments so
    /// the index stays a sorted, disjoint list.
    internal mutating func addFragment(offset: Int64, length: Int64) {
        guard length > 0, offset >= 0 else { return }
        var merged = RangeFragment(offset: offset, length: length)
        var kept: [RangeFragment] = []
        kept.reserveCapacity(fragments.count + 1)
        for fragment in fragments {
            if fragment.offset <= merged.end && merged.offset <= fragment.end {
                merged = RangeFragment(
                    offset: min(fragment.offset, merged.offset),
                    length: max(fragment.end, merged.end) - min(fragment.offset, merged.offset)
                )
            } else {
                kept.append(fragment)
            }
        }
        kept.append(merged)
        kept.sort { $0.offset < $1.offset }
        fragments = kept
    }

    /// Drops any stored bytes overlapping `range` (used when the file turns out
    /// to hold fewer bytes than the index claims).
    internal mutating func removeFragments(overlapping range: Range<Int64>) {
        guard !range.isEmpty else { return }
        var kept: [RangeFragment] = []
        kept.reserveCapacity(fragments.count)
        for fragment in fragments {
            let lower = max(fragment.offset, range.lowerBound)
            let upper = min(fragment.end, range.upperBound)
            guard lower < upper else {
                kept.append(fragment)
                continue
            }
            if fragment.offset < lower {
                kept.append(RangeFragment(offset: fragment.offset, length: lower - fragment.offset))
            }
            if upper < fragment.end {
                kept.append(RangeFragment(offset: upper, length: fragment.end - upper))
            }
        }
        fragments = kept
    }

    /// End of the stored run starting at `offset`; equals `offset` when no
    /// stored range covers it.
    internal func contiguousEnd(from offset: Int64) -> Int64 {
        var cursor = offset
        for fragment in fragments {
            if fragment.offset <= cursor, cursor < fragment.end {
                cursor = fragment.end
            } else if fragment.offset > cursor {
                break
            }
        }
        return cursor
    }
}

/// Atomic Codable persistence for the per-URL index sidecar. Writes go to a
/// temporary file in the same directory and are renamed over the old index, so
/// a crash can never leave a half-written index. Corrupt sidecars degrade to a
/// fresh index (bytes are re-fetched) instead of failing the load.
internal enum RangeIndexPersistence {
    internal static func indexURL(forDataURL dataURL: URL) -> URL {
        URL(fileURLWithPath: dataURL.path + ".idx", isDirectory: false)
    }

    internal static func load(dataURL: URL) -> RangeIndexStore? {
        let url = indexURL(forDataURL: dataURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let store = try? JSONDecoder().decode(RangeIndexStore.self, from: data),
            store.version == RangeIndexStore.currentVersion
        else {
            return nil
        }
        return store
    }

    internal static func save(_ store: RangeIndexStore, dataURL: URL) {
        let url = indexURL(forDataURL: dataURL)
        guard let data = try? JSONEncoder().encode(store) else { return }
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try? FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
            } else {
                try? FileManager.default.moveItem(at: temporaryURL, to: url)
            }
            try? FileManager.default.removeItem(at: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}
