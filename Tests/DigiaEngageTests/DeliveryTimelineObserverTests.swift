import Testing
@testable import DigiaEngage

/// The drop→stage mapping is the only reason→stage mapping in the SDK, and it
/// has to be **total**: every `DropReason` lands on a beat of the journey, so
/// the campaign creator's card never has a row with no place to sit.
///
/// The twin of the same assertion in Dart and Kotlin — if the three disagree,
/// one dashboard shows a drop under `gating` and another under `render` for the
/// same campaign.
@Suite("Delivery timeline observer")
struct DeliveryTimelineObserverTests {

    @Test("maps every drop reason onto the beat it happened on")
    func stageOfEveryDropReason() {
        #expect(stageOf(.notInitialized) == .trigger)
        #expect(stageOf(.notReady) == .trigger)
        #expect(stageOf(.initializationFailed) == .trigger)
        #expect(stageOf(.unknownCampaignKey) == .trigger)

        #expect(stageOf(.frequencyCapped) == .gating)
        #expect(stageOf(.screenNotTargeted) == .gating)
        #expect(stageOf(.surfaceBusy) == .gating)
        #expect(stageOf(.superseded) == .gating)

        #expect(stageOf(.invalidConfig) == .render)
        #expect(stageOf(.anchorNotRegistered) == .render)
        #expect(stageOf(.hostNotMounted) == .render)
        #expect(stageOf(.timeout) == .render)
        #expect(stageOf(.error) == .render)
        // Both mean the owner withdrew a campaign already on its way to the
        // screen, so they sit with the other render-stage endings.
        #expect(stageOf(.cancelled) == .render)
        #expect(stageOf(.pluginDetached) == .render)

        // Total by construction — if a reason is ever added, this count fails
        // before the mapping can silently acquire a default branch.
        #expect(DropReason.allCases.count == 15)
    }
}
