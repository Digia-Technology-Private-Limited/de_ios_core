import Testing

@testable import DigiaEngage

/// Pins the gamification wire strings shared with the backend
/// (`ai_docs/gamification/eng/README.md` "Shared contracts"). A rename here
/// breaks the contract; like `CEPInterfaceEnumValuesTests`, this fails first.
@Suite("Gamification enum wire values", .tags(.contract, .gamification))
struct GamificationEnumsTests {
    @Test("formats")
    func formats() {
        #expect(GamificationFormat(wire: "scratchCard") == .scratchCard)
        #expect(GamificationFormat(wire: "spinWheel") == .spinWheel)
        #expect(GamificationFormat(wire: "rewardChest") == .rewardChest)
        #expect(GamificationFormat(wire: "slotMachine") == .slotMachine)
        #expect(GamificationFormat(wire: "wheel").rawValue == "unknown")
        #expect(GamificationFormat(wire: nil).rawValue == "unknown")
    }

    @Test("entry, surface and sensors")
    func entrySurfaceSensors() {
        #expect(GamificationEntryKind(wire: "direct") == .direct)
        #expect(GamificationEntryKind(wire: "inlineTeaser") == .inlineTeaser)
        #expect(GamificationEntryKind(wire: "floating") == .floating)
        #expect(GamificationEntryKind(wire: "banner").rawValue == "unknown")
        #expect(GamificationSurfaceStyle(wire: "dialog") == .dialog)
        #expect(GamificationSurfaceStyle(wire: "bottomSheet") == .bottomSheet)
        #expect(GamificationSurfaceStyle(wire: "fullScreen") == .fullScreen)
        #expect(GamificationSurfaceStyle(wire: "sheet").rawValue == "unknown")
        #expect(GamificationSkinSensor(wire: "haptics") == .haptics)
        #expect(GamificationSkinSensor(wire: "gyroscope") == .gyroscope)
        #expect(GamificationSkinSensor(wire: "accelerometer") == .accelerometer)
        #expect(GamificationSkinSensor(wire: "nfc").rawValue == "unknown")
    }

    @Test("outcome, reward and refusal kinds")
    func outcomeRewardRefusal() {
        #expect(GamificationOutcomeKind(wire: "reward") == .reward)
        #expect(GamificationOutcomeKind(wire: "extraPlay") == .extraPlay)
        #expect(GamificationOutcomeKind(wire: "betterLuck") == .betterLuck)
        #expect(GamificationRewardType(wire: "coupon") == .coupon)
        #expect(GamificationRewardType(wire: "currency") == .currency)
        #expect(GamificationRewardType(wire: "perk") == .perk)
        for wire in [
            "notVerified", "notFound", "expired", "alreadyPlayed", "notPlayable", "busy",
        ] {
            #expect(GamificationPlayRefusal(wire: wire).rawValue == wire)
        }
        #expect(GamificationPlayRefusal(wire: "frozen") == .unavailable)
    }
}
