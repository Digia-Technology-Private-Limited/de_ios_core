import AVFoundation
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

// Nudge video (R2): the state-driven MediaVideo borrows its player from the
// pool under a fresh per-mount key and frees it when the nudge goes away.
// Every test below names the one production line whose change fails it; see
// ai_docs/meaningful-tests.md.

private final class NudgeLeaseFakeFactory: PlayerFactory {
    func makePlayer() -> AVQueuePlayer { AVQueuePlayer() }
}

@MainActor
@Suite("Nudge video lease", .tags(.nudge, .component, .media))
struct NudgeVideoLeaseTests {
    // Fails if the nudge video stops borrowing: with `keepAliveKey: nil` in
    // NudgeVideoPlayer.init the showing owns its player outright, so the pool
    // never holds a key while mounted.
    @Test("a mounted nudge video holds a pool key released on dismiss")
    func dismissReleasesKeyedLease() async throws {
        let factory = NudgeLeaseFakeFactory()
        let pool = VideoPlayerPool(factory: factory, maxPlayers: 2)
        var services = MediaServices.unconfigured
        services.pool = { pool }
        let window = mountMedia(
            NudgeColumnContent(column: try column(), onDismiss: {})
                .environment(\.mediaServices, services)
                .environment(\.digiaCampaignKey, "test-campaign")
        )

        let held = await waitUntilMedia { !pool.heldKeys().isEmpty }
        #expect(held, "the mounted nudge video borrows a pool key")
        #expect(pool.heldKeys().count == 1)
        ComponentTestHost.unmount(window)

        let freed = await waitUntilMedia { pool.heldKeys().isEmpty }
        #expect(freed, "dismissing the nudge frees its lease")
    }

    private func column() throws -> NudgeColumn {
        let config = try #require(try NudgeConfig.fromJson([
            "layout": [
                "type": "digia/column",
                "children": [
                    [
                        "type": "digia/videoPlayer",
                        "props": ["url": "https://example.invalid/nudge.mp4"]
                    ]
                ]
            ]
        ]))
        return config.layout
    }
}
