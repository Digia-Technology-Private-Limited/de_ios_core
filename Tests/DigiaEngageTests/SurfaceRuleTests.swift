import Testing

@testable import DigiaEngage

/// One case per cell of `ai_docs/surface-rule-plan.md` §2.1, written out
/// independently of `SurfaceRule.table` so a change to either is caught.
@Suite("Surface rule matrix")
struct SurfaceRuleTests {
    private static let slot = "home_banner"

    private static let arrivals: [(String, SurfaceKind)] = [
        ("nudge", .nudge),
        ("survey", .survey),
        ("guide", .guide),
        ("floater", .floaterCollapsed),
        ("inline", .inline(slot: slot)),
    ]

    private static let occupantKinds: [(String, SurfaceKind?)] = [
        ("nothing", nil),
        ("nudge", .nudge),
        ("survey", .survey),
        ("guide", .guide),
        ("floaterExpanded", .floaterExpanded),
        ("floaterCollapsed", .floaterCollapsed),
        ("inlineSameSlot", .inline(slot: slot)),
        ("inlineOtherSlot", .inline(slot: "other_slot")),
    ]

    /// S = show, B = busy, R = SR05 (never displayed → replace).
    private static let expected: [String: String] = [
        "nudge": "SBBBBSSS",
        "survey": "SBBBBSSS",
        "guide": "SBBBBSSS",
        "floater": "SBBBBBSS",
        "inline": "SSSSSSRS",
    ]

    static let cells: [(String, String)] = arrivals.flatMap { arrival in
        occupantKinds.map { (arrival.0, $0.0) }
    }

    private static func occupant(
        _ kind: SurfaceKind, key: String = "occ", displayed: Bool = false, liveTest: Bool = false
    ) -> SurfaceOccupant {
        SurfaceOccupant(
            kind: kind, campaignKey: key, cepCampaignId: "cep-\(key)",
            isLiveTest: liveTest, hasDisplayed: displayed)
    }

    @Test("each §2.1 cell", arguments: cells)
    func cell(arrivalName: String, occupantName: String) throws {
        let arrival = try #require(Self.arrivals.first { $0.0 == arrivalName }?.1)
        let index = try #require(Self.occupantKinds.firstIndex { $0.0 == occupantName })
        let kind = Self.occupantKinds[index].1
        let symbol = Array(try #require(Self.expected[arrivalName]))[index]
        let occupants = kind.map { [Self.occupant($0)] } ?? []

        let decision = SurfaceRule.decide(arrival, occupants: occupants)

        switch symbol {
        case "S": #expect(decision == .show)
        case "B": #expect(decision == .busy(blocker: occupants[0]))
        default: #expect(decision == .replace(occupants[0]))
        }
    }

    @Test("an expanded floater arriving reads the floater row")
    func expandedArrivalIsFloaterRow() {
        #expect(SurfaceRule.decide(.floaterExpanded, occupants: [Self.occupant(.floaterCollapsed)])
            == .busy(blocker: Self.occupant(.floaterCollapsed)))
    }

    @Test("same slot, displayed → busy")
    func sameSlotDisplayed() {
        let occ = Self.occupant(.inline(slot: Self.slot), displayed: true)
        #expect(SurfaceRule.decide(.inline(slot: Self.slot), occupants: [occ]) == .busy(blocker: occ))
    }

    @Test("same slot held by an undisplayed live test → busy (a real campaign never displaces a test)")
    func sameSlotLiveTest() {
        let occ = Self.occupant(.inline(slot: Self.slot), liveTest: true)
        #expect(SurfaceRule.decide(.inline(slot: Self.slot), occupants: [occ]) == .busy(blocker: occ))
    }

    @Test("with several occupants the blocking one is reported (§2.5)")
    func blockerPrecedence() {
        let collapsed = Self.occupant(.floaterCollapsed, key: "pip")
        let nudge = Self.occupant(.nudge, key: "welcome")
        #expect(SurfaceRule.decide(.floaterCollapsed, occupants: [collapsed, nudge])
            == .busy(blocker: nudge))
    }

    @Test("live test displaces every non-show occupant and keeps the rest")
    func liveTestDisplaced() {
        let nudge = Self.occupant(.nudge, key: "n")
        let collapsed = Self.occupant(.floaterCollapsed, key: "pip")
        let otherSlot = Self.occupant(.inline(slot: "other_slot"), key: "i")
        let all = [collapsed, otherSlot, nudge]

        #expect(SurfaceRule.liveTestDisplaced(.survey, occupants: all) == [nudge])
        #expect(SurfaceRule.liveTestDisplaced(.floaterCollapsed, occupants: all) == [nudge, collapsed])
        #expect(SurfaceRule.liveTestDisplaced(.inline(slot: "other_slot"), occupants: all) == [otherSlot])

        let displayed = Self.occupant(.inline(slot: Self.slot), displayed: true)
        #expect(SurfaceRule.liveTestDisplaced(.inline(slot: Self.slot), occupants: [displayed]) == [displayed])
    }
}
