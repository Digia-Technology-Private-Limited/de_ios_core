import Testing
@testable import DigiaEngage

/// Longhand pin of every CEP v2 wire string. The twin of Dart's
/// `cep_interface_enum_values_test.dart` and Kotlin's
/// `CepInterfaceEnumValuesTest.kt` — the three files spell the same strings, so
/// a rename on one stack fails a test rather than silently splitting the
/// analytics backend's vocabulary.
///
/// Every expectation is written out in full on purpose. Deriving the expected
/// value from the case would pin nothing.
@Suite("CEP v2 wire strings")
struct CEPInterfaceEnumValuesTests {

    @Test("PresentationState values")
    func presentationStateValues() {
        #expect(PresentationState.pending.value == "pending")
        #expect(PresentationState.displaying.value == "displaying")
        #expect(PresentationState.settled.value == "settled")
        #expect(PresentationState.allCases.count == 3)
    }

    @Test("DropReason values")
    func dropReasonValues() {
        #expect(DropReason.notInitialized.value == "not_initialized")
        #expect(DropReason.unknownCampaignKey.value == "unknown_campaign_key")
        #expect(DropReason.invalidConfig.value == "invalid_config")
        #expect(DropReason.anchorNotRegistered.value == "anchor_not_registered")
        #expect(DropReason.frequencyCapped.value == "frequency_capped")
        #expect(DropReason.screenNotTargeted.value == "screen_not_targeted")
        #expect(DropReason.surfaceBusy.value == "surface_busy")
        #expect(DropReason.superseded.value == "superseded")
        #expect(DropReason.hostNotMounted.value == "host_not_mounted")
        #expect(DropReason.timeout.value == "timeout")
        #expect(DropReason.cancelled.value == "cancelled")
        #expect(DropReason.pluginDetached.value == "plugin_detached")
        #expect(DropReason.error.value == "error")
        #expect(DropReason.allCases.count == 13)
    }

    @Test("DismissReason values")
    func dismissReasonValues() {
        #expect(DismissReason.userClose.value == "user_close")
        #expect(DismissReason.scrimTap.value == "scrim_tap")
        #expect(DismissReason.backGesture.value == "back_gesture")
        #expect(DismissReason.ctaAction.value == "cta_action")
        #expect(DismissReason.autoTimeout.value == "auto_timeout")
        #expect(DismissReason.screenExit.value == "screen_exit")
        #expect(DismissReason.targetLost.value == "target_lost")
        #expect(DismissReason.superseded.value == "superseded")
        #expect(DismissReason.completed.value == "completed")
        #expect(DismissReason.cancelled.value == "cancelled")
        #expect(DismissReason.pluginDetached.value == "plugin_detached")
        #expect(DismissReason.allCases.count == 11)
    }

    @Test("PresentationOutcome kinds carry the arm's reason value")
    func outcomeKinds() {
        let dismissed = PresentationOutcome.dismissed(reason: .userClose, completed: true)
        #expect(dismissed.kind == "dismissed")
        #expect(dismissed.reasonValue == "user_close")

        let dropped = PresentationOutcome.dropped(reason: .frequencyCapped, detail: nil)
        #expect(dropped.kind == "dropped")
        #expect(dropped.reasonValue == "frequency_capped")
    }

    @Test("PresentationSignal types")
    func signalTypes() {
        #expect(PresentationSignal.displayed.type == "displayed")
        #expect(PresentationSignal.clicked(elementId: nil).type == "clicked")
        #expect(PresentationSignal.clicked(elementId: "cta_primary").type == "clicked")
    }
}
