import Foundation
import Testing

/// Layering gates for the R2 media core (R3): every image, video and Lottie frame renders
/// through `internal/media/` (`MediaImage` / `MediaVideo` / `MediaLottie`, backed by the
/// pool + range cache), and `internal/media/` itself never reaches back into the SDK
/// singleton. The suite scans `Sources/` after blanking comments and string literals, so
/// commented-out code can neither hide a violation nor fake one.
///
/// Rule (a): `AVPlayer(` construction appears only in `PlayerFactory.swift` — the pool's
/// single seam (D3). Rule (b): the `AVPlayer` / `AVQueuePlayer` / `AVPlayerLayer` types
/// appear outside `internal/media/` only in the pinned borrower/observer residual below —
/// each entry hands an already-borrowed player to a layer or reads it back, never builds
/// one. Rule (c): `WebImage` / `LottieView` appear outside `internal/media/` only in the
/// two dedicated shells that predate the wrappers. Rule (d): no file under
/// `internal/media/` references `SDKInstance` (D17: services flow in, never looked up).
///
/// A stale pin fails too: when a residual is finally migrated, delete its line here.
@Suite("MediaArchitecture", .tags(.media, .unit))
struct MediaArchitectureTests {

    // MARK: - Pins (relative to Sources/DigiaEngage/)

    /// Borrower/observer residual for rule (b): each file names its owner + why it still
    /// names the type. `AVPlayerItem` / `AVPlayerViewController` intentional uses (cause
    /// reader, item builders, notification names) are NOT `AVPlayer` — the matcher uses
    /// word boundaries, so they never trip this gate.
    private static let avPlayerBorrowers: Set<String> = [
        // STORY driver (R2-STORY): `player` mirrors `MediaVideoState.activePlayer` for the
        // layer hosts and the handover chain; the player comes from the state, never built.
        "api/widgets/inline_story_video_playback.swift",
        // Shared raw layer for the story rail + floater/PIP (R2-STORY/FLOAT): takes an
        // already-borrowed player, never creates one. Harness seam (TF-6/TF-7).
        "api/widgets/inline_story_thumbnail_player.swift",
        // Handover-chain callback types (R2-STORY): pages borrow via state and forward the
        // instance; `(AVPlayer?) -> Void` names the type but builds nothing.
        "api/internal/story/pages/VideoStoryPage.swift",
        "api/internal/story/pages/CanvasStoryPage.swift",
        // Lease-backed computed player (R2-FLOAT): `videoState?.activePlayer`, no build.
        "api/internal/campaign/floater_orchestrator.swift",
        // Dedicated bare shell (R2-FLOAT): renders an already-borrowed player through the
        // shared layer; deliberately off the wrappers (needs Android bare+drivePlayback
        // equivalents first).
        "api/internal/utils/floater_media_view.swift",
        // Native controls stay OUTSIDE the frozen wrapper (R-G-01, accepted difference):
        // `PlayerViewController(player:)` is passive chrome over the state's player.
        "api/internal/campaign/nudge/NudgeNodeRenderer.swift",
        // `CanvasPoolBorrow` seam + dedicated canvas renderer shell (R2-SURFACES, mirrors
        // R-G-01): borrows via the factory, never constructs outside it.
        "api/internal/canvas/CampaignCanvasView.swift",
    ]

    /// Extra layer surfaces for rule (b): only the shared rail/floater layer names it.
    private static let avPlayerLayerHolders: Set<String> = [
        "api/widgets/inline_story_thumbnail_player.swift",
    ]

    /// Dedicated Lottie shells for rule (c) (accepted differences, mirror R-G-01): canvas
    /// and floater render `LottieView` directly off the warmed source instead of routing
    /// through `MediaLottie`. `WebImage` construction has no pin — it lives only in
    /// `MediaImage` (manager/error/codec uses elsewhere are not views).
    private static let lottieViewShells: Set<String> = [
        "api/internal/canvas/CampaignCanvasView.swift",
        "api/internal/utils/floater_media_view.swift",
    ]

    private static let mediaDir = "api/internal/media/"
    private static let factoryFile = "api/internal/media/PlayerFactory.swift"

    // MARK: - Gates

    // Fails if a player is constructed anywhere but the factory. The factory vends a bare
    // `AVQueuePlayer` (an `AVPlayer` subclass, for the looper — see `PlayerFactory.swift`),
    // so the gate has two halves: a bare `AVPlayer(` appears NOWHERE, and `AVQueuePlayer(`
    // appears ONLY in `PlayerFactory.swift`. Break-once: adding `let probe = AVPlayer()`
    // to `media_load_health.swift` fails the first half; `let probe = AVQueuePlayer()` in
    // `survey_renderer.swift` fails the second.
    @Test("player construction stays in PlayerFactory")
    func playerConstructionStaysInFactory() throws {
        let files = try scannedSources()
        let bare = filesMatching(files, pattern: #"AVPlayer\("#)
        #expect(
            bare.isEmpty,
            "bare AVPlayer( construction (the factory vends AVQueuePlayer): \(describe(bare, only: bare.keys.sorted()))"
        )
        let queue = filesMatching(files, pattern: #"AVQueuePlayer\("#)
        let outside = queue.keys.filter { $0 != Self.factoryFile }
        #expect(
            outside.isEmpty,
            "AVQueuePlayer( outside PlayerFactory.swift: \(describe(queue, only: outside))"
        )
        #expect(
            !(queue[Self.factoryFile]?.isEmpty ?? true),
            "PlayerFactory.swift no longer constructs AVQueuePlayer — the gate is vacuous"
        )
    }

    // Fails if the player types leak outside media/ beyond the pinned residual.
    // Break-once: adding `let probe: AVPlayer? = nil` to `survey_renderer.swift` fails here.
    @Test("player types stay in media except the pinned borrowers")
    func playerTypesStayInMediaExceptBorrowers() throws {
        let files = try scannedSources()
        let outside = files.filter { !$0.relative.hasPrefix(Self.mediaDir) }
        checkPin(
            token: "AVPlayer",
            pattern: #"\bAVPlayer\b"#,
            files: outside,
            expected: Self.avPlayerBorrowers
        )
        checkPin(
            token: "AVQueuePlayer",
            pattern: #"\bAVQueuePlayer\b"#,
            files: outside,
            expected: []
        )
        checkPin(
            token: "AVPlayerLayer",
            pattern: #"\bAVPlayerLayer\b"#,
            files: outside,
            expected: Self.avPlayerLayerHolders
        )
    }

    // Fails if image/Lottie views render outside media/ beyond the pinned shells.
    // Break-once: referencing `LottieView<EmptyView>` in `survey_renderer.swift` fails here.
    @Test("render views stay in media except the pinned shells")
    func renderViewsStayInMediaExceptShells() throws {
        let files = try scannedSources()
        let outside = files.filter { !$0.relative.hasPrefix(Self.mediaDir) }
        checkPin(
            token: "WebImage",
            pattern: #"\bWebImage\b"#,
            files: outside,
            expected: []
        )
        checkPin(
            token: "LottieView",
            pattern: #"\bLottieView\b"#,
            files: outside,
            expected: Self.lottieViewShells
        )
    }

    // Fails if the media core reaches back into the SDK singleton. Break-once: adding
    // `let probe: SDKInstance? = nil` to `MediaServices.swift` fails here.
    @Test("media core never references SDKInstance")
    func mediaCoreNeverReferencesSDKInstance() throws {
        let files = try scannedSources()
        let inside = files.filter { $0.relative.hasPrefix(Self.mediaDir) }
        checkPin(
            token: "SDKInstance",
            pattern: #"\bSDKInstance\b"#,
            files: inside,
            expected: []
        )
    }

    // MARK: - Scanner

    private struct ScannedFile {
        let relative: String
        let stripped: String
    }

    private func scannedSources(file: StaticString = #filePath) throws -> [ScannedFile] {
        let sources = try #require(
            Self.sourcesDirectory(file: file),
            "Sources/DigiaEngage/ not found above \(file)"
        )
        let enumerator = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var urls: [URL] = []
        while let element = enumerator?.nextObject() {
            if let url = element as? URL, url.pathExtension == "swift" {
                urls.append(url)
            }
        }
        try #require(!urls.isEmpty, "no Swift files under \(sources.path) — scan ran nowhere")
        return try urls.map { url in
            let text = try String(contentsOf: url, encoding: .utf8)
            return ScannedFile(
                relative: url.path.replacingOccurrences(of: sources.path + "/", with: ""),
                stripped: Self.blanked(text)
            )
        }
    }

    private static func sourcesDirectory(file: StaticString) -> URL? {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources/DigiaEngage")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue
            {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    /// Blanks `//` line comments (incl. `///` docs), `/* */` blocks (incl. `/** */`),
    /// and every string literal (`"…"`, `"""…"""`, `#"…"#`), keeping newlines so reported
    /// line numbers match the file. Commented-out code can neither hide nor fake a hit.
    private static func blanked(_ text: String) -> String {
        let chars = Array(text)
        var out = chars
        var i = 0
        func blank(_ at: Int) {
            if chars[at] != "\n" { out[at] = " " }
        }
        while i < chars.count {
            let c = chars[i]
            let n: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "/", n == "/" {
                var j = i
                while j < chars.count, chars[j] != "\n" { blank(j); j += 1 }
                i = j
                continue
            }
            if c == "/", n == "*" {
                var j = i
                var depth = 0
                while j < chars.count {
                    if chars[j] == "/", j + 1 < chars.count, chars[j + 1] == "*" {
                        depth += 1; blank(j); blank(j + 1); j += 2
                    } else if chars[j] == "*", j + 1 < chars.count, chars[j + 1] == "/" {
                        depth -= 1; blank(j); blank(j + 1); j += 2
                        if depth == 0 { break }
                    } else {
                        blank(j); j += 1
                    }
                }
                i = j
                continue
            }
            if c == "#" {
                var hashes = 0
                var j = i
                while j < chars.count, chars[j] == "#" { hashes += 1; j += 1 }
                if j < chars.count, chars[j] == "\"" {
                    var k = j + 1
                    let closer = "\"" + String(repeating: "#", count: hashes)
                    var found = false
                    while k < chars.count {
                        if chars[k] == "\\" { k += 2; continue }
                        if k + closer.count <= chars.count,
                           String(chars[k..<k + closer.count]) == closer
                        {
                            for m in i..<k + closer.count { blank(m) }
                            i = k + closer.count
                            found = true
                            break
                        }
                        k += 1
                    }
                    if found { continue }
                }
                i += 1
                continue
            }
            if c == "\"" {
                if i + 2 < chars.count, chars[i + 1] == "\"", chars[i + 2] == "\"" {
                    var k = i + 3
                    var found = false
                    while k + 2 < chars.count {
                        if chars[k] == "\"", chars[k + 1] == "\"", chars[k + 2] == "\"" {
                            for m in i..<k + 3 { blank(m) }
                            i = k + 3
                            found = true
                            break
                        }
                        k += 1
                    }
                    if found { continue }
                    i += 1
                    continue
                }
                var k = i + 1
                var found = false
                while k < chars.count {
                    if chars[k] == "\\" { k += 2; continue }
                    if chars[k] == "\"" || chars[k] == "\n" {
                        let endAtNewline = chars[k] == "\n"
                        for m in i..<k { blank(m) }
                        if !endAtNewline { blank(k) }
                        i = k + (endAtNewline ? 0 : 1)
                        found = true
                        break
                    }
                    k += 1
                }
                if found { continue }
                i += 1
                continue
            }
            i += 1
        }
        return String(out)
    }

    private func filesMatching(
        _ files: [ScannedFile],
        pattern: String
    ) -> [String: [Int]] {
        var hits: [String: [Int]] = [:]
        for file in files {
            var lines: [Int] = []
            for (index, line) in file.stripped.components(separatedBy: "\n").enumerated()
                where line.range(of: pattern, options: .regularExpression) != nil
            {
                lines.append(index + 1)
            }
            if !lines.isEmpty { hits[file.relative] = lines }
        }
        return hits
    }

    private func checkPin(
        token: String,
        pattern: String,
        files: [ScannedFile],
        expected: Set<String>
    ) {
        let hits = filesMatching(files, pattern: pattern)
        let actual = Set(hits.keys)
        let unexpected = actual.subtracting(expected).sorted()
        let stale = expected.subtracting(actual).sorted()
        #expect(
            unexpected.isEmpty,
            "`\(token)` outside its home in \(unexpected.count) unpinned file(s): \(describe(hits, only: unexpected))"
        )
        #expect(
            stale.isEmpty,
            "stale pin(s): `\(token)` no longer appears in \(stale.joined(separator: ", ")) — delete the line"
        )
    }

    private func describe(_ hits: [String: [Int]], only files: [String]) -> String {
        files.map { file in
            let lines = (hits[file] ?? []).prefix(3).map(String.init).joined(separator: ",")
            let extra = (hits[file] ?? []).count > 3 ? "+" : ""
            return "\(file):\(lines)\(extra)"
        }.joined(separator: "; ")
    }
}
