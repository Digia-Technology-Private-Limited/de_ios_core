import Testing
@testable import DigiaEngage

/// The controller's guarantees, keyed to the conformance-scenario IDs in the
/// CEP v2 spec (§4, G1–G8). The Kotlin twin
/// (`PresentationControllerTest.kt`) carries the same scenarios under the same
/// IDs; the Dart twin is `presentation_controller_test.dart`.
@Suite("PresentationController", .serialized)
@MainActor
struct PresentationControllerTests {

    private func makeTrigger(_ key: String = "welcome_offer") -> CEPTriggerPayload {
        CEPTriggerPayload(cepCampaignId: "cep-1", campaignKey: key, cepMetadata: [:])
    }

    private func makeController(
        onCancel: (@MainActor (PresentationController) -> Void)? = nil
    ) -> PresentationController {
        PresentationController(id: "p-1", trigger: makeTrigger(), onCancel: onCancel)
    }

    // MARK: - G1

    @Test("G1 — settle takes effect exactly once; later calls are no-ops")
    func settleExactlyOnce() async {
        let controller = makeController()
        let presentation = controller.presentation

        controller.settle(.dropped(reason: .frequencyCapped, detail: nil))
        controller.settle(.dropped(reason: .timeout, detail: "second call"))

        #expect(presentation.state == .settled)
        let outcome = await presentation.outcome.value
        #expect(outcome == .dropped(reason: .frequencyCapped, detail: nil))
    }

    @Test("G1 — a waiter attached before settlement is resumed by it")
    func outcomeResumesAPreAttachedWaiter() async {
        let controller = makeController()
        let presentation = controller.presentation

        let waiter = Task { @MainActor in await presentation.outcome.value }
        await Task.yield()
        #expect(presentation.outcome.isSettled == false)

        controller.markDisplaying()
        controller.settle(.dismissed(reason: .userClose, completed: false))

        #expect(await waiter.value == .dismissed(reason: .userClose, completed: false))
    }

    // MARK: - G3

    @Test("G3 — displayed fires at most once and never after settle")
    func displayedAtMostOnce() {
        let controller = makeController()
        var signals: [PresentationSignal] = []
        _ = controller.presentation.onSignal { signals.append($0) }

        controller.markDisplaying()
        controller.markDisplaying()
        #expect(signals == [.displayed])
        #expect(controller.state == .displaying)

        controller.settle(.dismissed(reason: .completed, completed: true))
        controller.markDisplaying()
        #expect(signals == [.displayed])
        #expect(controller.state == .settled)
    }

    @Test("G3 — a dropped presentation never emits displayed")
    func droppedNeverDisplays() {
        let controller = makeController()
        var signals: [PresentationSignal] = []
        _ = controller.presentation.onSignal { signals.append($0) }

        controller.settle(.dropped(reason: .anchorNotRegistered, detail: nil))

        #expect(signals.isEmpty)
    }

    // MARK: - G4

    @Test("G4 — no signals after the outcome")
    func noSignalsAfterOutcome() {
        let controller = makeController()
        var signals: [PresentationSignal] = []
        _ = controller.presentation.onSignal { signals.append($0) }

        controller.markDisplaying()
        controller.settle(.dismissed(reason: .userClose, completed: false))
        controller.emitClicked(elementId: "too_late")

        #expect(signals == [.displayed])
    }

    @Test("G4 — clicked between releaseHold and settle IS delivered")
    func clickedBetweenReleaseHoldAndSettleIsDelivered() {
        let controller = makeController()
        var signals: [PresentationSignal] = []
        _ = controller.presentation.onSignal { signals.append($0) }

        controller.markDisplaying()
        controller.releaseHold()
        controller.emitClicked(elementId: "cta_primary")

        #expect(signals == [.displayed, .clicked(elementId: "cta_primary")])
        #expect(controller.isHoldReleased)
        #expect(controller.isSettled == false)
    }

    @Test("G4 — an unsubscribed listener stops receiving, and unsubscribing twice is safe")
    func unsubscribeIsSafe() {
        let controller = makeController()
        var signals: [PresentationSignal] = []
        let unsubscribe = controller.presentation.onSignal { signals.append($0) }

        controller.markDisplaying()
        unsubscribe()
        unsubscribe()
        controller.emitClicked(elementId: nil)

        #expect(signals == [.displayed])
    }

    // MARK: - G5

    @Test("G5 — cancel while pending drops, and is idempotent")
    func cancelWhilePendingIsIdempotent() async {
        let controller = makeController()
        let presentation = controller.presentation

        presentation.cancel()
        presentation.cancel()

        #expect(await presentation.outcome.value == .dropped(reason: .cancelled, detail: nil))
    }

    @Test("G5 — cancel while displaying dismisses, and is a no-op once settled")
    func cancelWhileDisplayingThenAfterSettle() async {
        let controller = makeController()
        let presentation = controller.presentation

        controller.markDisplaying()
        presentation.cancel()
        presentation.cancel()

        #expect(
            await presentation.outcome.value
                == .dismissed(reason: .cancelled, completed: false)
        )
    }

    @Test("G5 — a cancel hook that settles itself wins over the backstop")
    func cancelHookSettlesFirst() async {
        let controller = makeController { controller in
            controller.settle(.dropped(reason: .superseded, detail: "closed by the CEP"))
        }
        let presentation = controller.presentation

        presentation.cancel()

        #expect(
            await presentation.outcome.value
                == .dropped(reason: .superseded, detail: "closed by the CEP")
        )
    }

    @Test("G5 — a cancel hook that settles nothing still reaches the backstop")
    func cancelHookBackstop() async {
        var hookRan = false
        let controller = makeController { _ in hookRan = true }
        let presentation = controller.presentation

        presentation.cancel()

        #expect(hookRan)
        #expect(await presentation.outcome.value == .dropped(reason: .cancelled, detail: nil))
    }

    // MARK: - G8

    @Test("G8 — a synchronous drop settles holdReleased before anyone can await it")
    func synchronousDropReleasesHold() async {
        let controller = makeController()
        let presentation = controller.presentation

        controller.settle(.dropped(reason: .unknownCampaignKey, detail: nil))

        // The designed path, not a race: deliver() can hand back an already
        // settled presentation, so a late awaiter must still fire.
        #expect(presentation.holdReleased.isSettled)
        await presentation.holdReleased.value
        #expect(presentation.outcome.isSettled)
    }

    @Test("G8 — settle releases the hold for a modal experience that never did")
    func settleReleasesHoldOnTheDismissedPath() async {
        let controller = makeController()
        let presentation = controller.presentation

        controller.markDisplaying()
        #expect(presentation.holdReleased.isSettled == false)

        controller.settle(.dismissed(reason: .screenExit, completed: false))

        #expect(presentation.holdReleased.isSettled)
        await presentation.holdReleased.value
    }

    @Test("G8 — releaseHold settles before the outcome, and is idempotent")
    func releaseHoldPrecedesTheOutcome() async {
        let controller = makeController()
        let presentation = controller.presentation

        controller.markDisplaying()
        controller.releaseHold()
        controller.releaseHold()

        #expect(presentation.holdReleased.isSettled)
        #expect(presentation.outcome.isSettled == false)

        controller.settle(.dismissed(reason: .completed, completed: true))
        #expect(presentation.outcome.isSettled)
    }

    @Test("G8 — cancel releases the hold too")
    func cancelReleasesHold() async {
        let controller = makeController()
        let presentation = controller.presentation

        presentation.cancel()

        #expect(presentation.holdReleased.isSettled)
        await presentation.holdReleased.value
    }

    @Test("G8 — a waiter attached before the release is resumed by it")
    func holdReleasedResumesAPreAttachedWaiter() async {
        let controller = makeController()
        let presentation = controller.presentation

        let waiter = Task { @MainActor in
            await presentation.holdReleased.value
            return presentation.state
        }
        await Task.yield()
        #expect(presentation.holdReleased.isSettled == false)

        controller.settle(.dropped(reason: .hostNotMounted, detail: nil))

        #expect(await waiter.value == .settled)
    }

    // MARK: - the read face

    @Test("the read face is a separate object from the write face")
    func readFaceIsNotTheController() {
        let controller = makeController()
        #expect(controller.presentation as AnyObject !== controller as AnyObject)
        #expect(controller.presentation.id == "p-1")
        #expect(controller.presentation.trigger.campaignKey == "welcome_offer")
    }
}
