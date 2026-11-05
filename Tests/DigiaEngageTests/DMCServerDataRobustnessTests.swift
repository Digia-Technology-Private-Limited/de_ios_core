import Foundation
import Testing
@testable import DigiaEngage

/// Server data must never crash the host app: numbers outside the machine's
/// range and look-alike types degrade to a defined result. Dart ints do not
/// trap, so the crash cases have no Flutter counterpart; the parity cases
/// mirror Dart's behaviour.
@MainActor
@Suite("DMC server data robustness")
struct DMCServerDataRobustnessTests {
    private static func json(_ text: String) -> Any {
        try! JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed)
    }

    private static func verdict(
        _ conditions: Any, attributes: [String: Any] = [:], device: [String: Any] = ["platform": "ios"]
    ) -> String {
        DMCRuleEvaluatorTests.verdictName(
            DMCRuleEvaluatorTests.run(
                DMCRuleEvaluatorTests.rule(conditions), attributes: attributes, device: device))
    }

    // MARK: wait delay

    @Test("a delay beyond any session is bounded, not a trap")
    func hugeDelayIsBounded() {
        for text in ["1e20", "9223372036854775807", "9.3e18", "1e15", "2e15"] {
            let rule = DMCRuleEvaluatorTests.rule(
                ["all": [Any]()],
                wait: ["type": "delay", "ms": Self.json(text)])
            guard case .valid(let valid) = parseRule(rule), let wait = valid.wait else {
                Issue.record("\(text): expected a valid wait")
                continue
            }
            #expect(wait.ms == 1_000_000_000_000_000, "\(text)")
        }
    }

    @Test("a delay of Int.max cannot overflow the end time")
    func waitsEndTimeSaturates() {
        let now = 5_000
        var fired = 0
        let waits = Waits(onElapsed: { _ in fired += 1 }, nowMs: { now })

        waits.start(
            [(campaignKey: "a", priority: 1, wait: RuleWait(ms: Int.max, cancels: []))],
            trigger: .appOpened, screen: "")
        waits.schedule()

        #expect(waits.isWaiting("a"))
        #expect(fired == 0)
        _ = waits.cancelAll()
    }

    // MARK: user context lifetime

    @Test("the context lifetime ignores anything that is not a sane number of seconds")
    func expirySeconds() {
        #expect(UserContextManager.expirySeconds(Self.json("1800")) == 1800)
        #expect(UserContextManager.expirySeconds(Self.json("60.9")) == 60)
        #expect(UserContextManager.expirySeconds(Self.json("-30")) == -30)
        #expect(UserContextManager.expirySeconds(Self.json("1e20")) == 900)
        #expect(UserContextManager.expirySeconds(Self.json("9223372036854775807")) == 900)
        #expect(UserContextManager.expirySeconds(Self.json("-1e20")) == 900)
        // Dart's `num` excludes bool, so true is not 1 second.
        #expect(UserContextManager.expirySeconds(Self.json("true")) == 900)
        #expect(UserContextManager.expirySeconds(Self.json("\"60\"")) == 900)
        #expect(UserContextManager.expirySeconds(nil) == 900)
    }

    // MARK: equality, versions, ordering

    @Test("a boolean equals only a boolean: true is not 1")
    func booleanIsNotANumber() {
        let one = Self.json("1"), zero = Self.json("0")
        let yes = Self.json("true"), no = Self.json("false")

        #expect(!ruleJSONEquals(yes, one))
        #expect(!ruleJSONEquals(one, yes))
        #expect(!ruleJSONEquals(no, zero))
        #expect(!ruleJSONEquals(zero, no))
        #expect(ruleJSONEquals(yes, yes))
        #expect(!ruleJSONEquals(yes, no))
        #expect(ruleJSONEquals(one, 1.0))
    }

    @Test("a rule comparing to true does not match the attribute 1")
    func booleanRuleVersusNumberAttribute() {
        let leaf: [String: Any] = ["type": "attribute", "key": "vip", "op": "eq", "value": true]
        let one = Self.json(#"{"vip": 1}"#) as! [String: Any]
        let yes = Self.json(#"{"vip": true}"#) as! [String: Any]

        #expect(Self.verdict(leaf, attributes: one) == "ineligible")
        #expect(Self.verdict(leaf, attributes: yes) == "eligible")
    }

    @Test("only ASCII digits count in a version part")
    func versionPartsAreAsciiDigits() {
        func verdict(_ actual: String, _ value: String) -> String {
            Self.verdict(
                ["type": "device", "key": "app_version", "op": "gte", "value": value],
                device: ["app_version": actual])
        }
        // Arabic-Indic three is a number to Character but not a digit to Dart.
        #expect(verdict("5.3\u{0663}", "5.4") == "ineligible")
        #expect(verdict("5.\u{0663}", "5.3") == "ineligible")
        #expect(verdict("5.3", "5.3") == "eligible")
    }

    @Test("equal priorities break by campaign key in UTF-16 code-unit order")
    func tieBreakIsUtf16() {
        // U+1F600 is the surrogate pair D83D DE00, which sorts below U+FFFF.
        #expect(compareByPriority(1, "tip_\u{1F600}", 1, "tip_\u{FFFF}") < 0)
        #expect(compareByPriority(1, "tip_\u{FFFF}", 1, "tip_\u{1F600}") > 0)
        // Canonically equal text is still a different key.
        #expect(compareByPriority(1, "\u{00E9}", 1, "e\u{0301}") != 0)
        #expect(compareByPriority(1, "a", 1, "a") == 0)
    }

    // MARK: text of a number

    @Test("a floating number prints with its point, as Dart does")
    func dartTextOfNumbers() {
        #expect(dartText(Self.json("1.0")) == "1.0")
        #expect(dartText(Self.json("2.5")) == "2.5")
        #expect(dartText(Self.json("1")) == "1")
        #expect(dartText(Self.json("true")) == "true")
    }

    // MARK: clock

    @Test("the wait clock never goes backwards")
    func monotonicClockNeverDecreases() {
        var previous = MonotonicClock.nowMs()
        #expect(previous > 0)
        for _ in 0..<10_000 {
            let now = MonotonicClock.nowMs()
            #expect(now >= previous)
            previous = now
        }
    }

    // MARK: threading

    @Test("work handed to onMain runs on the main thread, in call order, from any thread")
    func onMainHopsInOrder() async {
        final class Log: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [(Int, Bool)] = []
            func add(_ n: Int, _ onMain: Bool) { lock.withLock { entries.append((n, onMain)) } }
            var snapshot: [(Int, Bool)] { lock.withLock { entries } }
        }
        let log = Log()

        await Task.detached {
            for n in 0..<5 {
                Digia.onMain { log.add(n, Thread.isMainThread) }
            }
        }.value
        for _ in 0..<200 where log.snapshot.count < 5 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(log.snapshot.map(\.0) == [0, 1, 2, 3, 4])
        #expect(log.snapshot.allSatisfy { $0.1 })
    }
}
