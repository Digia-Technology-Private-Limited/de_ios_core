import Testing

@testable import DigiaEngage

/// The gamification row and column of `SurfaceRule.table`, written out
/// independently of the table so a change to either is caught. Guards the
/// T1 surface-rule addition: a game blocks like a nudge, and a shown game
/// blocks later modals.
@Suite("Gamification surface rule", .tags(.unit, .surface, .gamification))
struct GamificationSurfaceRuleTests {
    private static let slot = "home_banner"

    private static func occupant(_ kind: SurfaceKind, key: String = "occ") -> SurfaceOccupant {
        SurfaceOccupant(
            kind: kind, campaignKey: key, cepCampaignId: "cep-\(key)",
            isLiveTest: false, hasDisplayed: false)
    }

    /// S = show, B = busy.
    @Test("gamification arrival reads the blocking row", arguments: [
        ("nothing", nil as SurfaceKind?, "S"),
        ("nudge", .nudge, "B"),
        ("gamification", .gamification, "B"),
        ("survey", .survey, "B"),
        ("guide", .guide, "B"),
        ("floaterExpanded", .floaterExpanded, "B"),
        ("floaterCollapsed", .floaterCollapsed, "S"),
        ("inlineSameSlot", .inline(slot: slot), "S"),
        ("inlineOtherSlot", .inline(slot: "other_slot"), "S"),
    ])
    func arrival(occupantName: String, occupantKind: SurfaceKind?, symbol: String) {
        let occupants = occupantKind.map { [Self.occupant($0)] } ?? []

        let decision = SurfaceRule.decide(.gamification, occupants: occupants)

        switch symbol {
        case "S": #expect(decision == .show)
        case "B": #expect(decision == .busy(blocker: occupants[0]))
        default: Issue.record("unexpected symbol \(symbol)")
        }
    }

    @Test("a shown game blocks later modal arrivals")
    func occupantBlocksModals() {
        let game = Self.occupant(.gamification, key: "game")

        #expect(SurfaceRule.decide(.nudge, occupants: [game]) == .busy(blocker: game))
        #expect(SurfaceRule.decide(.gamification, occupants: [game]) == .busy(blocker: game))
        #expect(SurfaceRule.decide(.inline(slot: Self.slot), occupants: [game]) == .show)
    }

    @Test("a gamification live test displaces every non-show occupant")
    func liveTestDisplaced() {
        let game = Self.occupant(.gamification, key: "g")
        let nudge = Self.occupant(.nudge, key: "n")
        let collapsed = Self.occupant(.floaterCollapsed, key: "pip")

        #expect(SurfaceRule.liveTestDisplaced(.gamification, occupants: [nudge, game]) == [nudge, game])
        #expect(
            SurfaceRule.liveTestDisplaced(.gamification, occupants: [collapsed]) == [])
    }
}
