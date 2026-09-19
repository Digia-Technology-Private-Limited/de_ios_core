import Foundation
import Testing
@testable import DigiaEngage

/// The two rules on this screen that are contracts rather than layout: how
/// records bucket into delivery cards, and what happens to a symbol the screen
/// has never heard of. No tests for copy or for widget shape.
@MainActor
@Suite("Campaign timeline screen")
struct DigiaCampaignTimelineViewTests {

    private func record(
        _ message: String,
        presentationId: String? = nil,
        reason: DiagnosticReason? = nil,
        extras: [String: String] = [:]
    ) -> TimelineRecord {
        TimelineRecord(
            timestamp: Date(timeIntervalSince1970: 0),
            severity: .debug,
            tag: "DIGIA",
            message: message,
            stage: .render,
            reason: reason,
            campaignKey: "summer_sale",
            presentationId: presentationId,
            extras: extras
        )
    }

    /// A delivery keeps the position of its most recent record — so a campaign
    /// that was just dismissed rises to the top — while the rows inside it read
    /// oldest-first, because a card is a story and a story has an order.
    @Test("groups a delivery's records into one card, oldest first inside it")
    func groupsByPresentationId() {
        let entries = TimelineEntry.group([
            record("dismissed", presentationId: "p_7"),
            record("bundle fetched"),
            record("displayed", presentationId: "p_7"),
            record("delivered", presentationId: "p_7"),
        ])

        #expect(entries.count == 2)
        #expect(entries[0].isDelivery)
        #expect(entries[0].records.map(\.message) == ["delivered", "displayed", "dismissed"])
        #expect(entries[1].isDelivery == false)
        #expect(entries[1].records.map(\.message) == ["bundle fetched"])
    }

    @Test("two deliveries of one campaign are two cards")
    func separateCardsPerPresentation() {
        let entries = TimelineEntry.group([
            record("delivered", presentationId: "p_2"),
            record("delivered", presentationId: "p_1"),
        ])
        #expect(entries.count == 2)
        #expect(entries.map(\.id).count == Set(entries.map(\.id)).count)
    }

    /// A renderer that drops or throws on a symbol it does not know hides
    /// exactly the new thing someone is trying to debug. The vocabulary grows
    /// as features land, so the raw symbol is the correct fallback — ugly and
    /// completely usable.
    @Test("renders an unrecognised symbol as its raw wire string")
    func unknownSymbolRendersRaw() {
        #expect(
            DigiaCampaignTimelineView.sentence(record("x", reason: UnknownReason()))
                == "some_future_symbol")
        // No reason at all falls through to the developer message rather than
        // rendering an empty row.
        #expect(DigiaCampaignTimelineView.sentence(record("Campaign store populated")) == "Campaign store populated")
    }

    @Test("puts the one useful extra in front of a non-developer")
    func knownSymbolsReadAsSentences() {
        #expect(
            DigiaCampaignTimelineView.sentence(
                record("x", reason: TimelineReason.clicked, extras: ["elementId": "buy_now"]))
                == "Clicked \"buy_now\"")
        #expect(
            DigiaCampaignTimelineView.sentence(record("x", reason: DropReason.frequencyCapped))
                == "Not shown — frequency cap reached")
        #expect(
            DigiaCampaignTimelineView.sentence(record("x", reason: DismissReason.screenExit))
                == "Dismissed — left the screen")
    }
}

/// A reason from an SDK newer than this screen.
private struct UnknownReason: DiagnosticReason {
    let wire = "some_future_symbol"
}
