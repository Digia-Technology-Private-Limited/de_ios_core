import UIKit

/// The one prefetch layer every surface warms through (D1, D6): video byte ranges through the
/// range cache, images through the shared SDWebImage cache (the same loader `MediaImage`
/// renders through, so a warmed image is a cache hit at render), Lottie through Lottie's own
/// composition fetch. Callers never touch either store directly, so warming both stays a
/// prefetch detail.
///
/// `warmImage`/`warmLottie` suspend until the bytes decode and answer whether the surface has
/// something to show: floaters reveal the window only on true. The story plan driver uses the
/// fire-and-forget half (`enqueueImage`) instead — a story page warms ahead without gating
/// anything.
///
/// Never throws: a blank or still-templated (`{{ }}`) URL warms nothing and answers
/// nil/false/0; a failure is reported through health (unless there is no campaign to blame it
/// on) and answers nil/false/0 — the caller degrades to its still. Cancelling the caller
/// cancels the in-flight fetch.
///
/// This protocol is frozen for the run: lane H (T12) swaps the no-op stub below for the real
/// implementation without changing these signatures.
protocol MediaPrefetch: Sendable {
    /// Warms the image at `url` and answers the decoded image, or nil when there is nothing to
    /// show. Floaters gate their reveal on this.
    func warmImage(_ url: String) async -> UIImage?

    /// Enqueues `url` on the shared image loader without waiting: the story plan's image half.
    /// Failures surface at render through `MediaImage`.
    func enqueueImage(_ url: String)

    /// Warms bytes `[0, lengthBytes)` of `url`; answers the bytes cached for the request.
    func warmVideoBytes(url: String, lengthBytes: Int) async -> Int

    /// Warms the whole file of `url` (a server without Range support, or a whole-file plan
    /// action); answers the bytes cached for the request.
    func warmWholeVideo(url: String) async -> Int

    /// Warms the Lottie composition at `url` and answers whether it parsed.
    func warmLottie(_ url: String) async -> Bool
}

/// The W1 stand-in: warms nothing and answers "nothing to show", so floating surfaces can code
/// against `MediaPrefetch` before the real implementation lands in T12 (lane H). Never
/// throws and never reports: there is no fetch to fail.
struct NoopMediaPrefetch: MediaPrefetch {
    func warmImage(_ url: String) async -> UIImage? { nil }

    func enqueueImage(_ url: String) {}

    func warmVideoBytes(url: String, lengthBytes: Int) async -> Int { 0 }

    func warmWholeVideo(url: String) async -> Int { 0 }

    func warmLottie(_ url: String) async -> Bool { false }
}
