import Foundation
import Testing

@testable import DigiaEngage

/// The part only the coordinator can get wrong.
///
/// `PresentationControllerTests` already pins what a controller enforces about
/// itself (G1, G3, G4, G5, G8); this is about routing events to the *right*
/// controller, forgetting settled ones, the two watchdogs (G7), and detach (G6).
@MainActor
@Suite("PresentationCoordinator")
struct PresentationCoordinatorTests {
    private func makeCoordinator(
        acceptance: TimeInterval = 60,
        anchor: TimeInterval = 60,
        onCancelSurface: @escaping (String) -> Void = { _ in }
    ) -> (PresentationCoordinator, () -> [String]) {
        var minted = 0
        var ids: [String] = []
        let coordinator = PresentationCoordinator(
            idGenerator: {
                minted += 1
                let id = "p\(minted)"
                ids.append(id)
                return id
            },
            onCancelSurface: onCancelSurface,
            acceptanceTimeout: acceptance,
            anchorLayoutTimeout: anchor
        )
        return (coordinator, { ids })
    }

    private func payload(_ cepCampaignId: String, key: String = "campaign") -> CEPTriggerPayload {
        CEPTriggerPayload(cepCampaignId: cepCampaignId, campaignKey: key, cepMetadata: [:])
    }

    // MARK: - Ownership

    @Test("an event reaches the presentation that owns its payload and no other")
    func routesToTheOwner() {
        let (coordinator, _) = makeCoordinator()
        let first = coordinator.open(payload("a"), owner: "clevertap")
        let second = coordinator.open(payload("b"), owner: "clevertap")
        coordinator.accept(first, kind: .modal)
        coordinator.accept(second, kind: .modal)

        coordinator.handle(.impressed, payload: first.trigger)

        #expect(first.state == .displaying)
        #expect(second.state == .pending)
    }

    @Test("two deliveries of the same cepCampaignId stay distinct handles")
    func sameCepCampaignIdDoesNotCollide() {
        let (coordinator, _) = makeCoordinator()
        let first = coordinator.open(payload("same"), owner: "clevertap")
        let second = coordinator.open(payload("same"), owner: "clevertap")
        coordinator.accept(first, kind: .modal)
        coordinator.accept(second, kind: .modal)

        #expect(first.id != second.id)
        #expect(first.trigger.presentationId != second.trigger.presentationId)

        coordinator.handle(.dismissed(reason: .userClose), payload: second.trigger)

        #expect(second.isSettled)
        #expect(!first.isSettled)
    }

    @Test("an unstamped payload is a clean no-op")
    func unstampedPayloadIsIgnored() {
        let (coordinator, _) = makeCoordinator()
        let controller = coordinator.open(payload("a"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)

        // A live test's payload, or anything rendered before a plugin attached.
        coordinator.handle(.dismissed(reason: .userClose), payload: payload("a"))

        #expect(!controller.isSettled)
        #expect(coordinator.liveCount == 1)
    }

    // MARK: - Forgetting

    @Test("a settled presentation leaves the registry")
    func settledPresentationsAreForgotten() async {
        let (coordinator, _) = makeCoordinator()
        let controller = coordinator.open(payload("a"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)
        #expect(coordinator.liveCount == 1)

        controller.settle(.dropped(reason: .cancelled, detail: nil))
        await Task.yield()

        #expect(coordinator.liveCount == 0)
    }

    @Test("a settle the coordinator never saw still cleans up")
    func ownerCancelCleansUp() async {
        var cancelled: [String] = []
        let (coordinator, _) = makeCoordinator(onCancelSurface: { cancelled.append($0) })
        let controller = coordinator.open(payload("a"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)

        // Straight through the read face — cleanup hangs off `outcome`, not off
        // each settling path, so this reaches the registry too.
        controller.presentation.cancel()
        await Task.yield()

        #expect(cancelled == ["a"])
        #expect(coordinator.liveCount == 0)
    }

    // MARK: - PresentationKind

    @Test("modal holds the CEP to its outcome; floating and inline hand it back at the impression")
    func kindDecidesWhenTheHoldEnds() {
        let (coordinator, _) = makeCoordinator()
        let modal = coordinator.open(payload("m"), owner: "clevertap")
        let floating = coordinator.open(payload("f"), owner: "clevertap")
        let inline = coordinator.open(payload("i"), owner: "clevertap")
        coordinator.accept(modal, kind: .modal)
        coordinator.accept(floating, kind: .floating)
        coordinator.accept(inline, kind: .inline)

        coordinator.handle(.impressed, payload: modal.trigger)
        coordinator.handle(.impressed, payload: floating.trigger)
        coordinator.handle(.impressed, payload: inline.trigger)

        #expect(!modal.isHoldReleased)
        #expect(floating.isHoldReleased)
        #expect(inline.isHoldReleased)
        #expect(!floating.isSettled)
    }

    @Test("a click after the hold went back is still delivered")
    func clickAfterHoldRelease() {
        let (coordinator, _) = makeCoordinator()
        let controller = coordinator.open(payload("f"), owner: "clevertap")
        coordinator.accept(controller, kind: .floating)
        var signals: [PresentationSignal] = []
        _ = controller.presentation.onSignal { signals.append($0) }

        coordinator.handle(.impressed, payload: controller.trigger)
        coordinator.handle(.clicked(elementID: "cta"), payload: controller.trigger)

        #expect(controller.isHoldReleased)
        #expect(signals == [.displayed, .clicked(elementId: "cta")])
    }

    // MARK: - G7, the acceptance watchdog

    @Test("G7 — a presentation that never displays settles dropped(timeout)")
    func acceptanceWatchdogFires() async throws {
        let (coordinator, _) = makeCoordinator(acceptance: 0.02)
        let controller = coordinator.open(payload("a"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)

        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(controller.presentation.outcome.settledValue == .dropped(reason: .timeout, detail: "never displayed within the acceptance window"))
        #expect(controller.isHoldReleased)
        #expect(coordinator.liveCount == 0)
    }

    @Test("G7 — a timely impression disarms the acceptance watchdog")
    func acceptanceWatchdogDisarms() async throws {
        let (coordinator, _) = makeCoordinator(acceptance: 0.02)
        let controller = coordinator.open(payload("a"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)
        coordinator.handle(.impressed, payload: controller.trigger)

        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(!controller.isSettled)
    }

    @Test("G7 — inline arms no acceptance watchdog")
    func inlineIsNeverTimedOut() async throws {
        let (coordinator, _) = makeCoordinator(acceptance: 0.02)
        let controller = coordinator.open(payload("a"), owner: "clevertap")
        coordinator.accept(controller, kind: .inline)

        try await Task.sleep(nanoseconds: 120_000_000)

        // Legitimately pending until the user scrolls to its slot — possibly
        // never, and no CEP holds a lock on one.
        #expect(!controller.isSettled)
    }

    @Test("G7 — a watchdog never outlives its presentation")
    func watchdogDoesNotOutliveTheOutcome() async throws {
        let (coordinator, _) = makeCoordinator(acceptance: 0.02)
        let controller = coordinator.open(payload("a"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)
        controller.markDisplaying()
        controller.settle(.dismissed(reason: .userClose, completed: false))

        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(controller.presentation.outcome.settledValue?.reasonValue == "user_close")
    }

    // MARK: - G7, the anchor watchdog

    @Test("G7 — a displaying experience whose anchor never lays out settles dismissed(auto_timeout)")
    func anchorWatchdogFiresWhileDisplaying() async throws {
        var cancelled: [String] = []
        let (coordinator, _) = makeCoordinator(
            anchor: 0.02, onCancelSurface: { cancelled.append($0) })
        let controller = coordinator.open(payload("g"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal, awaitsAnchorLayout: true)
        controller.markDisplaying()

        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(controller.presentation.outcome.settledValue
            == .dismissed(reason: .autoTimeout, completed: false))
        // It settles first and tears the surface down second, so the teardown's
        // own `dismissed` cannot overwrite the watchdog's reason.
        #expect(cancelled == ["g"])
    }

    @Test("G7 — an anchor that never lays out and never displayed drops anchor_not_registered")
    func anchorWatchdogFiresWhilePending() async throws {
        let (coordinator, _) = makeCoordinator(anchor: 0.02)
        let controller = coordinator.open(payload("g"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal, awaitsAnchorLayout: true)

        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(controller.presentation.outcome.settledValue?.reasonValue
            == DropReason.anchorNotRegistered.value)
        #expect(controller.isHoldReleased)
    }

    @Test("G7 — noteAnchorLayout disarms the anchor watchdog")
    func anchorWatchdogDisarms() async throws {
        let (coordinator, _) = makeCoordinator(anchor: 0.02)
        let controller = coordinator.open(payload("g"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal, awaitsAnchorLayout: true)

        coordinator.noteAnchorLayout(for: controller.trigger)
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(!controller.isSettled)
    }

    @Test("G7 — an experience that owes no anchor arms no anchor watchdog")
    func anchorWatchdogNotArmedByDefault() async throws {
        let (coordinator, _) = makeCoordinator(anchor: 0.02)
        let controller = coordinator.open(payload("n"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)

        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(!controller.isSettled)
    }

    // MARK: - G6

    @Test("G6 — detach settles what the departing plugin owns and nothing else")
    func detachSettlesOnlyItsOwner() {
        let (coordinator, _) = makeCoordinator()
        let mine = coordinator.open(payload("a"), owner: "clevertap")
        let theirs = coordinator.open(payload("b"), owner: "webengage")
        coordinator.accept(mine, kind: .modal)
        coordinator.accept(theirs, kind: .modal)

        coordinator.detach(owner: "clevertap")

        #expect(mine.presentation.outcome.settledValue
            == .dropped(reason: .pluginDetached, detail: nil))
        #expect(!theirs.isSettled)
    }

    @Test("G6 — a displaying presentation settles dismissed, a pending one dropped")
    func detachPicksTheRightArm() {
        let (coordinator, _) = makeCoordinator()
        let displaying = coordinator.open(payload("a"), owner: "clevertap")
        let pending = coordinator.open(payload("b"), owner: "clevertap")
        coordinator.accept(displaying, kind: .modal)
        coordinator.accept(pending, kind: .modal)
        coordinator.handle(.impressed, payload: displaying.trigger)

        coordinator.detach(owner: "clevertap")

        #expect(displaying.presentation.outcome.settledValue
            == .dismissed(reason: .pluginDetached, completed: false))
        #expect(pending.presentation.outcome.settledValue
            == .dropped(reason: .pluginDetached, detail: nil))
        #expect(displaying.isHoldReleased)
        #expect(pending.isHoldReleased)
    }

    // MARK: - Normalisation

    @Test("a click before the impression promotes rather than raising")
    func clickBeforeImpressionPromotes() {
        let (coordinator, _) = makeCoordinator()
        let controller = coordinator.open(payload("a"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)
        var signals: [PresentationSignal] = []
        _ = controller.presentation.onSignal { signals.append($0) }

        // Reached from a gesture handler, on the host app's frame: asserting
        // here would break someone else's app for a stats blip.
        coordinator.handle(.clicked(elementID: "cta"), payload: controller.trigger)

        #expect(controller.state == .displaying)
        #expect(signals == [.displayed, .clicked(elementId: "cta")])
    }

    @Test("a dismissal before the impression settles dropped, not dismissed")
    func dismissBeforeImpressionDrops() {
        let (coordinator, _) = makeCoordinator()
        let controller = coordinator.open(payload("a"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)

        coordinator.handle(.dismissed(reason: .userClose), payload: controller.trigger)

        // `dismissed` would tell the CEP an impression happened that never did.
        #expect(controller.presentation.outcome.settledValue?.kind == "dropped")
        #expect(controller.presentation.outcome.settledValue?.reasonValue
            == DropReason.cancelled.value)
    }

    @Test("a supersede before the impression keeps its own reason")
    func supersedeBeforeImpressionStaysSuperseded() {
        let (coordinator, _) = makeCoordinator()
        let controller = coordinator.open(payload("a"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)

        coordinator.handle(.dismissed(reason: .superseded), payload: controller.trigger)

        #expect(controller.presentation.outcome.settledValue?.reasonValue
            == DropReason.superseded.value)
    }

    @Test("drop carries a reason the lifecycle channel has no word for")
    func dropCarriesItsOwnReason() {
        let (coordinator, _) = makeCoordinator()
        let controller = coordinator.open(payload("g"), owner: "clevertap")
        coordinator.accept(controller, kind: .modal)

        coordinator.drop(controller.trigger, reason: .anchorNotRegistered, detail: "no anchor")

        #expect(controller.presentation.outcome.settledValue
            == .dropped(reason: .anchorNotRegistered, detail: "no anchor"))
    }
}
