import Foundation
import Testing

@testable import DigiaEngage

/// The game prewarm's pure decision core: the single warm slot (who may take
/// or replace it), the 3 s offscreen grace and the 2 min idle limit. Each
/// case names the rule it pins; changing that rule's line fails it.
@Suite struct GamePrewarmPolicyTests {
    @Test func emptySlotWarms() {
        #expect(GamePrewarmPolicy.slot(
            currentKey: nil, currentSource: nil,
            incomingKey: "a", incomingSource: .entry) == .warm)
    }

    @Test func sameCampaignSameSourceKeeps() {
        #expect(GamePrewarmPolicy.slot(
            currentKey: "a", currentSource: .entry,
            incomingKey: "a", incomingSource: .entry) == .keep)
    }

    @Test func entryNeverReplacesDirect() {
        #expect(GamePrewarmPolicy.slot(
            currentKey: "a", currentSource: .direct,
            incomingKey: "b", incomingSource: .entry) == .skip)
        #expect(GamePrewarmPolicy.slot(
            currentKey: "a", currentSource: .direct,
            incomingKey: "a", incomingSource: .entry) == .skip)
    }

    @Test func newestEntryReplacesOlderEntry() {
        #expect(GamePrewarmPolicy.slot(
            currentKey: "a", currentSource: .entry,
            incomingKey: "b", incomingSource: .entry) == .replace)
    }

    @Test func directReplacesEntry() {
        #expect(GamePrewarmPolicy.slot(
            currentKey: "a", currentSource: .entry,
            incomingKey: "a", incomingSource: .direct) == .replace)
    }

    @Test func offscreenGraceIsThreeSeconds() {
        let hidden = Date(timeIntervalSince1970: 1_000)
        #expect(!GamePrewarmPolicy.shouldDiscardOffscreen(
            hiddenSince: hidden, now: hidden.addingTimeInterval(2.9)))
        #expect(GamePrewarmPolicy.shouldDiscardOffscreen(
            hiddenSince: hidden, now: hidden.addingTimeInterval(3.1)))
        #expect(!GamePrewarmPolicy.shouldDiscardOffscreen(
            hiddenSince: nil, now: hidden.addingTimeInterval(60)))
    }

    @Test func idleLimitIsTwoMinutes() {
        let warmed = Date(timeIntervalSince1970: 1_000)
        #expect(!GamePrewarmPolicy.isIdle(warmedAt: warmed, now: warmed.addingTimeInterval(119)))
        #expect(GamePrewarmPolicy.isIdle(warmedAt: warmed, now: warmed.addingTimeInterval(120)))
    }
}
