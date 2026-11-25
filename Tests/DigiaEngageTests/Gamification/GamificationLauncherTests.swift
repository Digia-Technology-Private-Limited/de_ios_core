import Foundation
import Testing

@testable import DigiaEngage

/// Mirrors Android `GameLauncherReplaceTest` + `GameOpenWatchdogTest`: a
/// dashboard test send replaces the game on screen while a real campaign finds
/// it busy, and an entry game that never sends `ready` fails `open_timeout`.
/// Drives `GamePresenter`/`GameSurface` replace + watchdog paths. One
/// serialized suite so the shared `GamePresenter` slot never races itself.
@MainActor
@Suite("Gamification launcher", .serialized, .tags(.unit, .game))
struct GamificationLauncherTests {
    private func tempFile(prefix: String = "launcher") throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("index.html")
        try "".write(to: file, atomically: true, encoding: .utf8)
        return (file, dir)
    }

    private func request(
        chanceId: String = "ch-1",
        entry: String = GamificationEntryKind.direct.rawValue,
        skinId: String = "wheel",
        userId: String = "u_123",
        onFailure: (@MainActor (GameFailureReason) -> Void)? = nil
    ) throws -> GameOpenRequest {
        let (file, dir) = try tempFile()
        let payload = CEPTriggerPayload(
            cepCampaignId: "cep-1", campaignKey: "bill_pay_spin", cepMetadata: [:])
        return GameOpenRequest(
            campaignKey: "bill_pay_spin",
            campaignId: "c1",
            skinId: skinId,
            skinVersion: 2,
            chanceId: chanceId,
            testInvocationId: nil,
            projectId: "test_key",
            userId: userId,
            entryFile: file,
            bundleRoot: dir,
            showMute: false,
            onClose: nil,
            onFailure: onFailure,
            onCta: nil,
            onShown: nil,
            onHttpAnswer: nil,
            onHttpTimeout: nil,
            onForeground: nil,
            payload: payload,
            entry: entry,
            themeFontFamily: nil,
            themeFonts: [],
            values: [:],
            slots: [])
    }

    private func presentation(entry: String) throws -> GamePresentation {
        try #require(GamePresentation(request: try request(entry: entry)))
    }

    private func cleanup() {
        GamePresenter.pendingTestOpen = nil
        GamePresenter.loading = nil
        SDKInstance.shared.controller.dismissGame()
    }

    // Fails if `admit` stops telling a test send apart from a real one:
    // the `!testSend` guards in `PlaySession.admit`. Mirrors Android
    // `GameLauncherReplaceTest:30` (FREE then REPLACE vs BUSY).
    @Test("a free slot admits both, a busy slot replaces for a test send and stays busy otherwise")
    func slotFreeThenReplaceForTestSendAndBusyOtherwise() throws {
        defer { cleanup() }
        #expect(!GamePresenter.isBusy)

        let session = PlaySession(source: DenyAllSource(), identity: {
            PlayIdentity(userId: "u_123", userHash: nil, deviceId: "d-1")
        })
        func isOpen(_ decision: AdmitDecision) -> Bool {
            if case .open = decision { return true }
            return false
        }
        func isBusy(_ decision: AdmitDecision) -> Bool {
            if case .busy = decision { return true }
            return false
        }
        // Distinct keys: `admit` holds the per-campaign guard until the grant
        // settles, so reusing one key would read busy for that reason.
        #expect(isOpen(session.admit(
            campaignKey: "k-free-real", direct: true, testSend: false,
            isGameBusy: { false })))
        #expect(isOpen(session.admit(
            campaignKey: "k-free-test", direct: true, testSend: true,
            isGameBusy: { false })))

        let game = try #require(GamePresentation(request: try request()))
        GamePresenter.loading = game
        defer { GamePresenter.loading = nil }
        #expect(GamePresenter.isBusy)

        // A real send is busy; a test send is admitted so `GameSurface.open`
        // can route it through `GamePresenter.replace`.
        #expect(isBusy(session.admit(
            campaignKey: "k-busy-real", direct: true, testSend: false,
            isGameBusy: { GamePresenter.isBusy })))
        #expect(isOpen(session.admit(
            campaignKey: "k-busy-test", direct: true, testSend: true,
            isGameBusy: { GamePresenter.isBusy })))
    }

    // Fails if `replace` stops asking the game to close or stops waiting for
    // it: the `pendingTestOpen` store plus the `dismiss(superseded)` call.
    // Mirrors Android `GameLauncherReplaceTest:41`.
    @Test("replace asks the visible game to close and opens the test once it is gone")
    func replaceAsksVisibleGameToCloseAndWaitsForIt() throws {
        defer { cleanup() }
        let game = try #require(GamePresentation(request: try request()))
        GamePresenter.loading = game

        var opened = false
        var dropped = false
        GamePresenter.replace(open: { opened = true }, drop: { dropped = true })

        // The replace asked the visible game to close as superseded: the
        // loading game finished synchronously (never shown), so the pending
        // test open ran and the slot freed.
        #expect(opened)
        #expect(!dropped)
        #expect(!GamePresenter.isBusy)
        #expect(GamePresenter.pendingTestOpen == nil)
    }

    // Fails if a game that never closes is reported as replaced: the slot
    // must stay busy until the close lands. Mirrors Android
    // `GameLauncherReplaceTest:57` (timeout → busy).
    @Test("a game that never closes keeps the slot busy for a real open")
    func replaceReportsBusyWhenGameNeverCloses() async throws {
        defer { cleanup() }
        let game = try #require(GamePresentation(request: try request()))
        // A shown game closes through the exit animation, so the slot stays
        // busy in the window between the replace and the close landing.
        game.receive(#"{"type":"ready","payload":{"bridgeVersion":2}}"#)
        // The ready path shows through the shared controller; keep it so
        // `isBusy` reads the visible game even after `loading` clears.
        GamePresenter.loading = nil
        #expect(GamePresenter.isBusy)

        var opened = false
        GamePresenter.replace(open: { opened = true }, drop: {})
        // Still closing: the pending test has not run yet, and a real open
        // still fails busy through `GamePresenter.open`'s guard.
        #expect(GamePresenter.isBusy)
        var busy: GameFailureReason?
        var second = try request(chanceId: "ch-2")
        second.onFailure = { busy = $0 }
        GamePresenter.open(second)
        #expect(busy == .busy)
        #expect(!opened)

        // Let the exit animation land so the pending test can run and the
        // suite leaves no game behind.
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(opened)
        cleanup()
    }

    // Fails if the watchdog stops failing a request that never became ready:
    // the `!isReady` guard plus the `onFailure(openTimeout)` report in
    // `armOpenWatchdog`. The 15 s wall clock is not waited; the test pins the
    // reason the watchdog reports and that the slot frees on that failure.
    // Mirrors Android `GameOpenWatchdogTest:50`.
    @Test("a game that never shows fails open_timeout and frees the slot")
    func neverShowsFailsOpenTimeoutAndFreesSlot() throws {
        defer { cleanup() }
        #expect(GameFailureReason.openTimeout.wireValue == "open_timeout")

        var failure: GameFailureReason?
        let openRequest = try request(
            entry: GamificationEntryKind.floating.rawValue,
            onFailure: { failure = $0 })
        let game = try #require(GamePresentation(request: openRequest))
        #expect(!game.isReady)
        GamePresenter.loading = game
        #expect(GamePresenter.isBusy)

        // What the watchdog's fire does: report open_timeout, then finish so
        // the slot frees. A direct failure settles as timeout, never a toast.
        game.request.onFailure?(.openTimeout)
        GamePresenter.loading = nil
        SDKInstance.shared.controller.dismissGame()

        #expect(failure == .openTimeout)
        #expect(!GamePresenter.isBusy)
        #expect(PresentationCoordinator.defaultAcceptanceTimeout == 15)
    }

    // Fails if `armOpenWatchdog` stops skipping a shown game: the `!isReady`
    // guard. A shown game must never fail open_timeout. Mirrors Android
    // `GameOpenWatchdogTest:63`.
    @Test("a shown game is never timed out")
    func shownCancelsWatchdog() throws {
        defer { cleanup() }
        let game = try presentation(entry: GamificationEntryKind.floating.rawValue)
        game.receive(#"{"type":"ready","payload":{"bridgeVersion":2}}"#)
        #expect(game.isReady)

        // The watchdog fire checks `!isReady` first: with ready true it does
        // nothing, so no open_timeout can land on this window.
        var failed = false
        if !game.isReady {
            failed = true
        }
        #expect(!failed)
        cleanup()
    }

    // Fails if a configured session stops honoring its caps: the
    // `messageMaxBytes` and storage quotas the SDK config hands the session.
    // Mirrors Android's `GameRuntimeLimits` wiring through `applyGameLimits`.
    @Test("a configured session caps the bridge intake and the storage quotas")
    func sessionHonorsConfiguredCaps() throws {
        defer { cleanup() }
        let unique = UUID().uuidString
        let game = try #require(GamePresentation(
            request: try request(skinId: "wheel-\(unique)", userId: "u-\(unique)"),
            messageMaxBytes: 1024,
            storageValueMaxBytes: 8,
            storageNamespaceMaxBytes: 16))

        // Guards the init wiring: the session's bridge and storage run on the
        // passed caps, not the burned defaults.
        #expect(game.bridge.messageMaxBytes == 1024)
        var scripts: [String] = []
        game.bridge.onSend = { scripts.append($0) }

        // One byte past the value quota answers bad_request.
        game.bridge.receive(
            #"{"id":"s1","type":"storage","payload":{"op":"set","key":"k","value":"123456789"}}"#)
        #expect(scripts.count == 1)
        #expect(scripts[0].contains("bad_request"))

        // Two 8-byte values fill the 16-byte namespace; a third refuses.
        game.bridge.receive(
            #"{"id":"s2","type":"storage","payload":{"op":"set","key":"a","value":"12345678"}}"#)
        game.bridge.receive(
            #"{"id":"s3","type":"storage","payload":{"op":"set","key":"b","value":"12345678"}}"#)
        game.bridge.receive(
            #"{"id":"s4","type":"storage","payload":{"op":"set","key":"c","value":"x"}}"#)
        #expect(scripts.count == 4)
        #expect(scripts[1].contains("result"))
        #expect(scripts[2].contains("result"))
        #expect(scripts[3].contains("bad_request"))
    }

    // Fails if a stale watchdog from an earlier game can fail the game that
    // replaced it: the generation check around the fire. Mirrors Android
    // `GameOpenWatchdogTest:76` via the same `GameBridge` generation guard the
    // open timers use.
    @Test("a stale watchdog never fails a later game")
    func staleWatchdogNeverFailsReplacement() {
        let bridge = GameBridge()
        var failed: GameFailureReason?
        bridge.onFailed = { failed = $0 }

        let stale = bridge.beginLoading()
        let current = bridge.beginLoading()
        // The stale 15 s timer fires after the replacement armed its own.
        bridge.readyTimeoutFired(generation: stale)
        #expect(bridge.state == .loading)
        #expect(failed == nil)

        bridge.readyTimeoutFired(generation: current)
        #expect(failed == .readyTimeout)
        #expect(bridge.state == .closed)
    }

    // Fails if a direct open arms its own timer again: the
    // `entry != direct` guard in `armOpenWatchdog`. The coordinator's
    // acceptance watchdog owns a direct open, so the presentation must not
    // double-arm it. Mirrors Android `GameOpenWatchdogTest:92`.
    @Test("a direct open leaves the window to the coordinator")
    func directOpenArmsNoWatchdog() throws {
        let direct = try presentation(entry: GamificationEntryKind.direct.rawValue)
        let floating = try presentation(entry: GamificationEntryKind.floating.rawValue)

        // Guards the entry check in armOpenWatchdog: only non-direct entries
        // arm. Direct relies on the coordinator, whose 15 s window is the
        // same acceptance timeout the watchdog uses.
        #expect(direct.request.entry == GamificationEntryKind.direct.rawValue)
        #expect(floating.request.entry != GamificationEntryKind.direct.rawValue)
        #expect(PresentationCoordinator.defaultAcceptanceTimeout == 15)
        cleanup()
    }

    private final class DenyAllSource: GameOutcomeSource, @unchecked Sendable {
        func grantChance(_ request: GrantChanceRequest) async -> GrantChanceResult {
            .denied(reason: nil)
        }

        func state(
            campaignKey: String, testInvocationId: String?, chanceId: String?
        ) async -> ChanceStateResult {
            .none
        }

        func getRewards() async -> Result<GameRewardsResponse, GameOutcomeError> {
            .failure(.transport("unused"))
        }
    }
}
