import Foundation
import Testing
@testable import DigiaEngage

/// Port of Flutter `test/dmc_rule_wait_test.dart` — the parse and `Waits`
/// groups. The SDKInstance group lands with the router port.
@Suite("DMC rule wait")
@MainActor
struct DMCRuleWaitTests {

    static func rule(wait: [String: Any]? = nil) -> [String: Any] {
        var json: [String: Any] = [
            "priority": 600,
            "trigger": ["any": [["type": "app_opened"]]],
            "conditions": ["all": []],
        ]
        if let wait { json["wait"] = wait }
        return json
    }

    // MARK: - parse

    @Test("reads the wait and each cancel type")
    func parsesCancels() throws {
        let parsed = parseRule(
            Self.rule(wait: [
                "type": "delay",
                "ms": 20000,
                "cancel": [
                    "any": [
                        ["type": "event", "name": "submitted"],
                        ["type": "screen_viewed", "names": ["cart"]],
                        ["type": "screen_left"],
                        ["type": "screen_left", "names": ["address"]],
                    ]
                ],
            ]))
        guard case .valid(let rule) = parsed, let wait = rule.wait else {
            Issue.record("expected a valid wait")
            return
        }
        #expect(wait.ms == 20000)
        #expect(wait.cancels.count == 4)
        guard case .onScreenLeft(let none) = wait.cancels[2] else {
            Issue.record("expected screen_left")
            return
        }
        #expect(none == nil)
        guard case .onScreenLeft(let address) = wait.cancels[3] else {
            Issue.record("expected screen_left with names")
            return
        }
        #expect(address == ["address"])
    }

    @Test("a rule without wait has none")
    func noWait() {
        guard case .valid(let rule) = parseRule(Self.rule()) else {
            Issue.record("expected a valid rule")
            return
        }
        #expect(rule.wait == nil)
    }

    @Test("a wait without cancel cancels on nothing")
    func noCancel() {
        guard case .valid(let rule) = parseRule(
            Self.rule(wait: ["type": "delay", "ms": 1000])),
            let wait = rule.wait
        else {
            Issue.record("expected a valid wait")
            return
        }
        #expect(wait.cancels.isEmpty)
    }

    @Test("bad waits are malformed")
    func malformedWaits() {
        let cases: [(String, [String: Any])] = [
            ("ms of zero", ["type": "delay", "ms": 0]),
            ("a fraction", ["type": "delay", "ms": 1.5]),
            ("cancel with no any", ["type": "delay", "ms": 1000, "cancel": [:]]),
            (
                "empty screen_left names",
                [
                    "type": "delay", "ms": 1000,
                    "cancel": ["any": [["type": "screen_left", "names": []]]],
                ]
            ),
        ]
        for (name, wait) in cases {
            guard case .invalid(let rule) = parseRule(Self.rule(wait: wait)) else {
                Issue.record("expected an invalid rule for \(name)")
                continue
            }
            #expect(rule.reason == .malformedRule, "\(name)")
        }
    }

    @Test("an unknown wait or cancel type is an unsupported feature")
    func unknownWaitTypes() {
        let waits: [[String: Any]] = [
            ["type": "snooze", "ms": 1000],
            ["type": "delay", "ms": 1000, "cancel": ["any": [["type": "app_opened"]]]],
            ["type": "delay", "ms": 1000, "cancel": ["any": [["type": "session_event"]]]],
        ]
        for wait in waits {
            guard case .invalid(let rule) = parseRule(Self.rule(wait: wait)) else {
                Issue.record("expected an invalid rule for \(wait)")
                continue
            }
            #expect(rule.reason == .unsupportedFeature)
        }
    }

    // MARK: - Waits

    @MainActor final class Harness {
        var now = 0
        var elapsed: [[String]] = []
        var waits: Waits!

        init() {
            waits = Waits(
                onElapsed: { [unowned self] due in
                    elapsed.append(due.map(\.campaignKey))
                },
                nowMs: { [unowned self] in now })
        }

        func advance(_ ms: Int) {
            now += ms
            waits.schedule()
        }
    }

    func wait(_ ms: Int, _ cancels: [CancelCondition] = []) -> RuleWait {
        RuleWait(ms: ms, cancels: cancels)
    }

    @Test("fires after the delay, not before")
    func firesAfterDelay() {
        let harness = Harness()
        harness.waits.start(
            [("a", 1, wait(20000))], trigger: .screenViewed("login"), screen: "login")

        harness.advance(19999)
        #expect(harness.elapsed.isEmpty)
        harness.advance(1)
        #expect(harness.elapsed == [["a"]])
        #expect(!harness.waits.isWaiting("a"))
    }

    @Test("a second start of a waiting campaign keeps the first timer")
    func secondStartKeepsTimer() {
        let harness = Harness()
        harness.waits.start(
            [("a", 1, wait(20000))], trigger: .screenViewed("login"), screen: "login")
        harness.advance(15000)
        harness.waits.start(
            [("a", 1, wait(20000))], trigger: .screenViewed("login"), screen: "login")

        harness.advance(5000)
        #expect(harness.elapsed == [["a"]])
        harness.advance(20000)
        #expect(harness.elapsed.count == 1)
    }

    @Test("waits of different campaigns run in parallel")
    func parallelWaits() {
        let harness = Harness()
        harness.waits.start(
            [("a", 1, wait(20000))], trigger: .screenViewed("login"), screen: "login")
        harness.waits.start(
            [("b", 2, wait(5000))], trigger: .screenViewed("login"), screen: "login")

        harness.advance(5000)
        #expect(harness.elapsed == [["b"]])
        #expect(harness.waits.isWaiting("a"))
        harness.advance(15000)
        #expect(harness.elapsed.last == ["a"])
    }

    @Test("waits that end at the same moment come in priority order")
    func sameMomentPriorityOrder() {
        let harness = Harness()
        harness.waits.start(
            [("low", 400, wait(1000))], trigger: .screenViewed("login"), screen: "login")
        harness.waits.start(
            [("high", 800, wait(1000))], trigger: .screenViewed("login"), screen: "login")

        harness.advance(1000)
        #expect(harness.elapsed == [["high", "low"]])
    }

    @Test("waits that already ended compete together, highest first")
    func alreadyEnded() {
        let harness = Harness()
        harness.waits.start(
            [("low", 400, wait(1000)), ("high", 800, wait(1000))],
            trigger: .screenViewed("login"), screen: "login", elapsedMs: 5000)
        #expect(harness.elapsed == [["high", "low"]])
    }

    @Test("background time counts; an ended wait fires on resume")
    func backgroundTimeCounts() {
        let harness = Harness()
        harness.waits.start(
            [("a", 1, wait(20000))], trigger: .screenViewed("login"), screen: "login")
        harness.waits.start(
            [("b", 2, wait(300000))], trigger: .screenViewed("login"), screen: "login")
        harness.advance(12000)

        harness.waits.pause()
        harness.advance(180000)
        #expect(harness.elapsed.isEmpty)

        harness.waits.resume()
        #expect(harness.elapsed == [["a"]])
        harness.advance(107999)
        #expect(harness.elapsed.count == 1)
        harness.advance(1)
        #expect(harness.elapsed.last == ["b"])
    }

    @Test("an event cancels only when its props match")
    func eventProps() {
        let harness = Harness()
        harness.waits.start(
            [(
                "a", 1,
                wait(
                    1000,
                    [
                        .onSignal(
                            .event(
                                name: "submitted",
                                where: .comparison(
                                    Comparison(
                                        source: .prop, key: "valid", op: .eq,
                                        value: true))))
                    ])
            )],
            trigger: .screenViewed("login"), screen: "login")

        #expect(
            harness.waits.cancelMatching(.event("submitted", ["valid": false]))
                .isEmpty)
        let cancelled = harness.waits.cancelMatching(
            .event("submitted", ["valid": true]))
        #expect(cancelled.single?.1 == .event)
        harness.advance(1000)
        #expect(harness.elapsed.isEmpty)
    }

    @Test("a screen view cancels on a listed screen")
    func screenViewCancel() {
        let harness = Harness()
        harness.waits.start(
            [(
                "a", 1,
                wait(1000, [.onSignal(.screenViewed(names: ["cart"]))])
            )],
            trigger: .screenViewed("login"), screen: "login")

        #expect(harness.waits.cancelMatching(.screenViewed("home")).isEmpty)
        #expect(harness.waits.cancelMatching(.screenViewed("cart")).single?.1 == .screenViewed)
    }

    @Test("screen_left without names compares with the start screen")
    func screenLeftStartScreen() {
        let harness = Harness()
        harness.waits.start(
            [("a", 1, wait(1000, [.onScreenLeft(names: nil)]))],
            trigger: .screenViewed("login"), screen: "login")

        #expect(harness.waits.cancelMatching(.screenViewed("login")).isEmpty)
        #expect(harness.waits.cancelMatching(.event("login", [:])).isEmpty)
        #expect(harness.waits.cancelMatching(.screenViewed("home")).single?.1 == .screenLeft)
    }

    @Test("screen_left with names cancels outside the names")
    func screenLeftNames() {
        let harness = Harness()
        harness.waits.start(
            [(
                "a", 1,
                wait(1000, [.onScreenLeft(names: ["login", "otp"])])
            )],
            trigger: .screenViewed("login"), screen: "login")

        #expect(harness.waits.cancelMatching(.screenViewed("otp")).isEmpty)
        #expect(!harness.waits.cancelMatching(.screenViewed("home")).isEmpty)
    }

    @Test("screen_left without names cancels on a different screen, and no screen counts as one")
    func screenLeftEmptyStart() {
        let harness = Harness()
        harness.waits.start(
            [("a", 1, wait(1000, [.onScreenLeft(names: nil)]))],
            trigger: .screenViewed("login"), screen: "")

        #expect(harness.waits.cancelMatching(.screenViewed("")).isEmpty)
        #expect(harness.waits.cancelMatching(.screenViewed("home")).single?.1 == .screenLeft)
    }

    @Test("the first cancel that matches decides the cause")
    func firstCancelWins() {
        let harness = Harness()
        harness.waits.start(
            [
                (
                    "a", 1,
                    wait(
                        1000,
                        [
                            .onSignal(.event(name: "submitted", where: nil)),
                            .onScreenLeft(names: ["login"]),
                            .onSignal(.screenViewed(names: ["login"])),
                        ])
                ),
                (
                    "b", 2,
                    wait(
                        1000,
                        [
                            .onScreenLeft(names: ["login"]),
                            .onSignal(.screenViewed(names: ["home"])),
                        ])
                ),
            ],
            trigger: .screenViewed("login"), screen: "login")

        let cancelled = harness.waits.cancelMatching(.screenViewed("login"))
        #expect(cancelled.single?.0.campaignKey == "a")
        #expect(cancelled.single?.1 == .screenViewed)

        let rest = harness.waits.cancelMatching(.screenViewed("home"))
        #expect(rest.single?.1 == .screenLeft)
    }

    @Test("one signal ends every wait it cancels")
    func oneSignalManyWaits() {
        let harness = Harness()
        let cancel: [CancelCondition] = [.onSignal(.event(name: "submitted", where: nil))]
        harness.waits.start(
            [
                ("a", 1, wait(1000, cancel)),
                ("b", 2, wait(2000)),
                ("c", 3, wait(3000, cancel)),
            ],
            trigger: .screenViewed("login"), screen: "login")

        #expect(harness.waits.cancelMatching(.event("submitted", [:])).count == 2)
        #expect(!harness.waits.isWaiting("a"))
        #expect(!harness.waits.isWaiting("c"))
        #expect(harness.waits.isWaiting("b"))
    }

    @Test("a new wait joins the pending ones in the same start call")
    func newWaitJoins() {
        let harness = Harness()
        harness.waits.start(
            [("a", 1, wait(2000))], trigger: .screenViewed("login"),
            screen: "login", elapsedMs: 1000)
        harness.waits.start(
            [("a", 1, wait(2000)), ("b", 2, wait(1000))],
            trigger: .screenViewed("login"), screen: "login")

        #expect(harness.waits.isWaiting("a"))
        #expect(harness.waits.isWaiting("b"))
    }

    @Test("a 30-minute wait is the dashboard maximum and runs intact")
    func maximumWait() {
        let harness = Harness()
        let max = 30 * 60 * 1000
        guard case .valid(let rule) = parseRule(
            Self.rule(wait: ["type": "delay", "ms": max])),
            let parsed = rule.wait
        else {
            Issue.record("expected a valid wait")
            return
        }
        #expect(parsed.ms == max)

        harness.waits.start(
            [("a", 1, parsed)], trigger: .screenViewed("login"), screen: "login")
        harness.advance(max - 1)
        #expect(harness.elapsed.isEmpty)
        harness.advance(1)
        #expect(harness.elapsed == [["a"]])
    }

    @Test("cancelAll ends every wait, as on a session end")
    func cancelAll() {
        let harness = Harness()
        harness.waits.start(
            [("a", 1, wait(1000))], trigger: .screenViewed("login"), screen: "")
        harness.waits.start(
            [("b", 2, wait(2000))], trigger: .screenViewed("login"), screen: "")

        let keys = Set(harness.waits.cancelAll().map(\.campaignKey))
        #expect(keys == ["a", "b"])
        harness.advance(2000)
        #expect(harness.elapsed.isEmpty)
        #expect(harness.waits.cancelAll().isEmpty)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
