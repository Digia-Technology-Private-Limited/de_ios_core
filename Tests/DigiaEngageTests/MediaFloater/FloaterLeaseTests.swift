import AVFoundation
import Foundation
import Testing
@testable import DigiaEngage

/// R2-FLOAT: the PiP showing borrows `pip-<campaignKey>` through a `MediaVideoState`
/// and releases it on every teardown path. The window draws the same leased instance
/// it prepared, so expand/collapse/mute never rebuild or restart playback.
///
/// All tests drive a private orchestrator (never the SDK-shared one) with a counting
/// factory, so the borrow lands in the showing-scoped seam pool: hermetic, no network,
/// local test-kit file only.
@Suite(
    "Floater: pip lease lifecycle", .serialized, .tags(.integration, .media, .floater, .pip),
    .enabled(if: testkitAvailable, testkitSkipReason))
struct FloaterLeaseTests {

    @MainActor
    private func makeOrchestrator() -> FloaterOrchestrator {
        FloaterOrchestrator(
            onDismissed: { _, _, _, _ in },
            onCompleted: { _ in },
            onStepViewed: { _ in },
            onStepDismissed: { _ in },
            onVisible: { _ in }
        )
    }

    private func loadVideoCampaign(targets: [String] = []) throws -> CampaignModel {
        var json = try fixture("pip/pip_mute_toggle")
        if !targets.isEmpty { json["targetScreenNames"] = ["names": targets] }
        let campaign = try CampaignModel.fromJson(json, designTokens: fixtureTokens(json))
        return try #require(campaign, "pip_mute_toggle must decode to a campaign")
    }

    /// Starts a video showing on a private orchestrator and waits for its first frame.
    @MainActor
    private func startVideo(
        _ orchestrator: FloaterOrchestrator, _ campaign: CampaignModel, screenName: String? = nil
    ) async throws -> Bool {
        let payload = CEPTriggerPayload(
            cepCampaignId: "cep-lease-test", campaignKey: campaign.campaignKey, cepMetadata: [:])
        let started = orchestrator.start(campaign, payload: payload, screenName: screenName)
        guard started else { return false }
        for _ in 0..<500 where orchestrator.awaitingMedia {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(orchestrator.state != nil, "Video showing was abandoned while loading")
        try #require(!orchestrator.awaitingMedia, "Video showing never reached its first frame")
        return true
    }

    /// Waits for an animated dismiss to finish tearing down.
    @MainActor
    private func waitForTeardown(_ orchestrator: FloaterOrchestrator) async throws {
        for _ in 0..<500 where orchestrator.state != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(orchestrator.state == nil, "Showing never tore down")
    }

    // Fails if: floater_orchestrator.swift `pipKeepAliveKey` `"pip-\(campaignKey)"` ->
    // `"floater-\(campaignKey)"` (the borrow lands under a different key).
    // Fails if: floater_orchestrator.swift `setMuted` `videoState?.spec.playback.muted`
    // is deleted (the mute toggle never reaches the live player).
    @Test("the showing borrows pip-<campaignKey> and renders the same instance across expand, collapse and mute")
    @MainActor
    func sameInstanceHandoverThroughState() async throws {
        let orchestrator = makeOrchestrator()
        let factory = CountingPlayerFactory()
        orchestrator.playerFactory = factory
        defer { orchestrator.playerFactory = nil; orchestrator.dispose() }
        let campaign = try loadVideoCampaign()
        try #require(try await startVideo(orchestrator, campaign))

        let pool = try #require(orchestrator.seamPool)
        #expect(pool.heldKeys() == ["pip-\(campaign.campaignKey)"])
        let first = try #require(orchestrator.player)

        orchestrator.expand()
        orchestrator.collapse()
        // Both directions must reach the live player: the take-over applies the
        // authored startMuted, so each flip below is a real transition either way.
        orchestrator.setMuted(false)
        #expect(orchestrator.player?.isMuted == false)
        orchestrator.setMuted(true)
        #expect(orchestrator.player?.isMuted == true)
        orchestrator.togglePlayback()
        orchestrator.togglePlayback()

        #expect(orchestrator.player === first)
        #expect(factory.builds == 1)
        #expect(pool.heldKeys() == ["pip-\(campaign.campaignKey)"])
    }

    // Fails if: floater_orchestrator.swift `finishDismiss` `videoState?.disappear()` is
    // deleted (the lease stays held after the window is gone).
    @Test("dismiss releases the lease")
    @MainActor
    func dismissReleasesLease() async throws {
        let orchestrator = makeOrchestrator()
        orchestrator.playerFactory = CountingPlayerFactory()
        defer { orchestrator.playerFactory = nil }
        let campaign = try loadVideoCampaign()
        try #require(try await startVideo(orchestrator, campaign))
        let pool = try #require(orchestrator.seamPool)
        try #require(pool.heldKeys() == ["pip-\(campaign.campaignKey)"])

        orchestrator.dismiss(.userClose)
        try await waitForTeardown(orchestrator)

        #expect(orchestrator.player == nil)
        #expect(pool.heldKeys().isEmpty)
    }

    // Fails if: floater_orchestrator.swift `dispose` `videoState?.disappear()` is deleted
    // (host teardown leaves the lease held).
    @Test("dispose releases the lease")
    @MainActor
    func disposeReleasesLease() async throws {
        let orchestrator = makeOrchestrator()
        orchestrator.playerFactory = CountingPlayerFactory()
        defer { orchestrator.playerFactory = nil }
        let campaign = try loadVideoCampaign()
        try #require(try await startVideo(orchestrator, campaign))
        let pool = try #require(orchestrator.seamPool)

        orchestrator.dispose()

        #expect(orchestrator.player == nil)
        #expect(pool.heldKeys().isEmpty)
    }

    // Fails if: floater_orchestrator.swift `onScreenChanged` `dismiss(.screenExit)` is
    // deleted (leaving a targeted screen leaves the lease held).
    @Test("screen-exit cover releases the lease")
    @MainActor
    func screenExitReleasesLease() async throws {
        let orchestrator = makeOrchestrator()
        orchestrator.playerFactory = CountingPlayerFactory()
        defer { orchestrator.playerFactory = nil }
        let campaign = try loadVideoCampaign(targets: ["home"])
        let payload = CEPTriggerPayload(
            cepCampaignId: "cep-lease-test", campaignKey: campaign.campaignKey, cepMetadata: [:])
        try #require(orchestrator.start(campaign, payload: payload, screenName: "home"))
        for _ in 0..<500 where orchestrator.awaitingMedia {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try #require(orchestrator.state != nil && !orchestrator.awaitingMedia)
        let pool = try #require(orchestrator.seamPool)

        orchestrator.onScreenChanged("away")
        try await waitForTeardown(orchestrator)

        #expect(orchestrator.player == nil)
        #expect(pool.heldKeys().isEmpty)
    }

    // Fails if: floater_orchestrator.swift `onGiveUp` `abandonMedia(token:reason:cause:)`
    // is deleted (a refused borrow leaves an awaiting showing that never resolves).
    @Test("a refused borrow drops the campaign without disturbing the holder")
    @MainActor
    func refusedBorrowAbandons() async throws {
        let orchestrator = makeOrchestrator()
        orchestrator.playerFactory = CountingPlayerFactory()
        defer { orchestrator.playerFactory = nil }
        let campaign = try loadVideoCampaign()
        let pool = try #require(orchestrator.seamPool)
        let otherURL = try #require(URL(string: campaign.floaterConfig!.media.url))
        pool.obtain(key: "other", url: otherURL, priority: .onScreen)?.pause()

        let payload = CEPTriggerPayload(
            cepCampaignId: "cep-lease-test", campaignKey: campaign.campaignKey, cepMetadata: [:])
        let started = orchestrator.start(campaign, payload: payload, screenName: nil)

        #expect(!started)
        #expect(orchestrator.player == nil)
        #expect(pool.heldKeys() == ["other"])
        #expect(orchestrator.lastStartFailureReason != nil)
    }

    // Crash-guard, not a leak probe: `pool.release()` already clears holders, so the
    // assertions below only prove teardown after external pool invalidation stays
    // silent (the lease release is a post-eviction no-op via `giveBackIfHeldBy`).
    // The genuine pin is the re-start: teardown must leave the orchestrator and the
    // pool usable, so the same campaign is accepted and reaches its first frame again.
    // Fails if: floater_orchestrator.swift `dispose` `state = nil` is deleted (the
    // re-start below is refused as busy).
    @Test("teardown after a pool release is silent")
    @MainActor
    func postEvictionTeardownIsSilent() async throws {
        let orchestrator = makeOrchestrator()
        orchestrator.playerFactory = CountingPlayerFactory()
        defer { orchestrator.playerFactory = nil }
        let campaign = try loadVideoCampaign()
        try #require(try await startVideo(orchestrator, campaign))
        let pool = try #require(orchestrator.seamPool)

        // The SDK-teardown analog: the pool drops every holder first.
        pool.release()
        orchestrator.dismiss(.hostTeardown)
        orchestrator.dispose()

        #expect(orchestrator.player == nil)
        #expect(pool.heldKeys().isEmpty)

        // The pool and the orchestrator must still serve the same campaign.
        try #require(try await startVideo(orchestrator, campaign))
        #expect(orchestrator.player != nil)
        orchestrator.dispose()
    }
}

/// A `PlayerFactory` that counts builds, vending plain players.
private final class CountingPlayerFactory: PlayerFactory {
    var builds = 0
    func makePlayer() -> AVQueuePlayer {
        builds += 1
        return AVQueuePlayer()
    }
}
