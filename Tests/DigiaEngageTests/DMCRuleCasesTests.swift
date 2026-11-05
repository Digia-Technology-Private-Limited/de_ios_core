import Foundation
import XCTest

@testable import DigiaEngage

// dmc-case: rule-corpus (testkit/rule-cases/<area>/<id>.json).
// Runs every assertion-based case in the shared `testkit/rule-cases` corpus
// through the real engine — the decision engine on a fake clock, with the SDK
// shell replaced by `Facts` answers computed from the case's context, audience
// flags and the real `FrequencyEvaluator`. `scheduling/` is backend-enforced
// and skipped. Mirrors Flutter `test/dmc_rule_cases_test.dart` (see also
// Android `DmcRuleCasesTest`); the format and what "shown" covers are in
// `testkit/rule-cases/README.md`.
//
// The corpus lives outside the package, so it is found by walking up from this
// file to a `testkit/rule-cases` directory (or `DIGIA_RULE_CASES`), the way
// Android's `RuleCaseFiles` walks up from the module. No resource is committed.

private enum RuleCaseFiles {
    static let areas: Set<String> = [
        "who", "when", "combined", "variables", "priority", "frequency",
    ]
    static let difficulties: Set<String> = ["easy", "simple", "complex", "very_hard"]

    static let root: URL? = makeRoot()

    private static func makeRoot() -> URL? {
        if let env = ProcessInfo.processInfo.environment["DIGIA_RULE_CASES"],
           !env.isEmpty
        {
            let url = URL(fileURLWithPath: env, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        var dir = URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()
        for _ in 0 ..< 12 {
            let candidate = dir.appendingPathComponent("testkit/rule-cases", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue
            {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    struct Loaded {
        var cases: [(file: String, json: [String: Any])] = []
        var problems: [String] = []
    }

    nonisolated(unsafe) static let loaded: Loaded = makeLoaded()

    private static func makeLoaded() -> Loaded {
        var out = Loaded()
        guard let root else { return out }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return out }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "json" {
            files.append(url)
        }
        files.sort { $0.path < $1.path }
        var seen: [String: String] = [:]
        for file in files {
            // Suffix after `rule-cases/`, robust to symlinked prefixes
            // (the simulator may report a resolved path).
            guard let marker = file.path.range(of: "rule-cases/") else { continue }
            let relative = String(file.path[marker.upperBound...])
            let parts = relative.split(separator: "/").map(String.init)
            if parts.first == "scheduling" { continue }
            let name = String(file.deletingPathExtension().lastPathComponent)
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                out.problems.append("\(relative): not valid JSON")
                continue
            }
            var issues: [String] = []
            if json["id"] as? String != name { issues.append("id mismatch") }
            if parts.count != 2 { issues.append("must sit directly in <area>/") }
            if let area = json["area"] as? String {
                if !areas.contains(area) { issues.append("unknown area \(area)") }
                if parts.count == 2, area != parts.first { issues.append("area != folder") }
            } else { issues.append("missing area") }
            if let difficulty = json["difficulty"] as? String {
                if !difficulties.contains(difficulty) { issues.append("unknown difficulty") }
            } else { issues.append("missing difficulty") }
            if (json["title"] as? String)?.isEmpty != false { issues.append("missing title") }
            if (json["covers"] as? [Any])?.isEmpty != false { issues.append("covers empty") }
            if (json["campaigns"] as? [Any])?.isEmpty != false { issues.append("campaigns empty") }
            if (json["steps"] as? [Any])?.isEmpty != false { issues.append("steps empty") }
            if let earlier = seen[name] {
                issues.append("duplicate id, also in \(earlier)")
            }
            seen[name] = relative
            if issues.isEmpty {
                out.cases.append((relative, json))
            } else {
                out.problems.append("\(relative): \(issues.joined(separator: "; "))")
            }
        }
        return out
    }
}

/// The corpus is unwalkable while a wait's timer owns the runloop, so a route
/// the surface refuses throws instead of recording anything.
private struct RouterDropped: Error {}

@MainActor
final class DMCRuleCasesTests: XCTestCase {
    /// Cases that fail against this SDK today without touching production
    /// code. Each is wrapped in `XCTExpectFailure` naming the case, so the
    /// suite stays green; the honest reasons live in
    /// `testkit/.../evidence/c-ios-missing.md` §2.
    private let knownRed: Set<String> = [
        "identified_condition_follows_login_and_logout",
        "newline_inside_braces_is_whitespace",
        "waits_end_together_dropped_lead_falls_through",
        "waits_end_together_lead_routes",
        "zero_never_prints_a_sign",
    ]

    func testCatalogIsValidAndIdsAreUnique() throws {
        try XCTSkipUnless(
            RuleCaseFiles.root != nil,
            "Test Kit rule cases not found; run `bash clone.sh` in de_workspace")
        XCTAssertTrue(
            RuleCaseFiles.loaded.problems.isEmpty,
            RuleCaseFiles.loaded.problems.joined(separator: "\n"))
        XCTAssertFalse(RuleCaseFiles.loaded.cases.isEmpty)
    }

    func testRuleCases() throws {
        try XCTSkipUnless(
            RuleCaseFiles.root != nil,
            "Test Kit rule cases not found; run `bash clone.sh` in de_workspace")
        var passed = 0
        var failed: [String] = []
        XCTAssertFalse(
            RuleCaseFiles.loaded.cases.isEmpty,
            "no rule cases loaded from \(RuleCaseFiles.root?.path ?? "?")")
        for (file, json) in RuleCaseFiles.loaded.cases {
            let id = json["id"] as? String ?? file
            let problems = World(file: file, json: json).run()
            if problems.isEmpty {
                passed += 1
                continue
            }
            let report = "\(id):\n" + problems.map { "  - \($0)" }.joined(separator: "\n")
            if knownRed.contains(id) {
                XCTExpectFailure("runner red: \(id)") {
                    XCTFail(report)
                }
            } else {
                failed.append(report)
            }
        }
        // swiftlint:disable:next line_length
        print("DMCRuleCases: \(passed) passed, \(failed.count) failed, \(knownRed.count) expected-failing, of \(RuleCaseFiles.loaded.cases.count) corpus cases")
        XCTAssertTrue(
            failed.isEmpty,
            "\(failed.count) rule cases failed:\n" + failed.joined(separator: "\n"))
    }

    // MARK: - Cases named in testkit/contracts/dmc-cases.json

    /// Runs the named corpus cases (`<area>/<id>`) and fails on any problem.
    private func runCases(_ names: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        try XCTSkipUnless(
            RuleCaseFiles.root != nil,
            "Test Kit rule cases not found; run `bash clone.sh` in de_workspace")
        for name in names {
            guard let found = RuleCaseFiles.loaded.cases.first(where: { $0.file == name + ".json" }) else {
                XCTFail("rule case \(name) not found", file: file, line: line)
                continue
            }
            let problems = World(file: found.file, json: found.json).run()
            XCTAssertTrue(
                problems.isEmpty, "\(name):\n" + problems.joined(separator: "\n"), file: file, line: line)
        }
    }

    // dmc-case: dmc.freq.max_total_zero_never_shows
    func testZeroCapNeverShows() throws {
        try runCases([
            "frequency/max_total_zero_never_shows",
            "frequency/max_per_window_zero_never_shows",
        ])
    }

    // dmc-case: dmc.priority.audience_gate
    func testAudienceGate() throws {
        try runCases([
            "priority/audience_gate_applies_only_to_gated_campaigns",
            "priority/in_audience_wins",
            "priority/not_in_audience_steps_aside",
            "priority/audience_gate_then_cap_then_priority",
            "combined/audience_gate_with_conditions",
            "combined/event_filter_and_audience_conditions",
        ])
    }

    // dmc-case: dmc.priority.equal_priority_rotates_through_caps
    func testEqualPriorityRotatesThroughCaps() throws {
        try runCases(["priority/equal_priority_rotates_through_caps"])
    }

    // dmc-case: dmc.priority.inline_never_capped
    func testInlineNeverCapped() throws {
        try runCases([
            "frequency/inline_total_cap_is_ignored",
            "frequency/inline_window_cap_is_ignored",
            "frequency/inline_exhausted_history_does_not_block",
        ])
    }

    // dmc-case: dmc.priority.waiting_campaign_does_not_block_lower_priority
    func testWaitingCampaignDoesNotBlockLowerPriority() throws {
        try runCases(["combined/waiting_campaign_does_not_block_lower_priority"])
    }

    // dmc-case: dmc.rule_when.event_where_compares_typed_props
    func testEventWhereComparesTypedProps() throws {
        try runCases(["when/event_where_prop_types"])
    }

    // dmc-case: dmc.rule_when.event_where_unknown_op_unsupported
    func testEventWhereUnknownOpUnsupported() throws {
        try runCases(["when/event_where_unsupported"])
    }

    // dmc-case: dmc.rule_who.contains_exists_type_edges
    func testContainsExistsTypeEdges() throws {
        try runCases(["who/list_and_falsy_values"])
    }

    // dmc-case: dmc.rule_who.in_matches_exact_json_types
    func testInMatchesExactJsonTypes() throws {
        try runCases(["who/in_operator_types"])
    }

    // dmc-case: dmc.rule_who.locale_platform_operators
    func testLocalePlatformOperators() throws {
        try runCases(["who/device_locale_and_platform_operators"])
    }

    // dmc-case: dmc.rule_who.platform_condition_gates_on_host
    func testPlatformConditionGatesOnHost() throws {
        try runCases(["who/device_attributes"])
    }

    // dmc-case: dmc.show_on.inline_ignores_screens
    func testInlineIgnoresScreens() throws {
        try runCases(["combined/inline_ignores_screens"])
    }

    // dmc-case: dmc.show_on.leave_and_return_in_time_still_shows
    func testLeaveAndReturnInTimeStillShows() throws {
        try runCases(["combined/wait_not_on_target_screen_survives_leave_and_return"])
    }

    // dmc-case: dmc.show_on.wait_ending_off_target_cancelled
    func testWaitEndingOffTargetCancelled() throws {
        try runCases(["combined/wait_not_on_target_screen_cancels_and_does_not_compete"])
    }

    // dmc-case: dmc.trigger.any_listed_trigger_matches_with_own_where
    func testAnyListedTriggerMatchesWithOwnWhere() throws {
        try runCases(["when/multiple_triggers_any"])
    }

    // dmc-case: dmc.trigger.each_trigger_type_matches_only_its_signal
    func testEachTriggerTypeMatchesOnlyItsSignal() throws {
        try runCases(["combined/each_trigger_type_shows_its_campaign"])
    }

    // dmc-case: dmc.trigger.same_event_two_triggers_shows_once
    func testSameEventTwoTriggersShowsOnce() throws {
        try runCases(["combined/same_event_two_triggers_shows_once"])
    }

    // dmc-case: dmc.trigger.signal_type_must_match_trigger_type
    func testSignalTypeMustMatchTriggerType() throws {
        try runCases(["when/signal_type_must_match"])
    }

    // dmc-case: dmc.wait_cancel.start_signal_cannot_cancel_itself
    func testStartSignalCannotCancelItself() throws {
        try runCases(["combined/wait_start_signal_cannot_cancel_itself"])
    }
}

@MainActor
private final class World: DecisionFacts {
    static let startMs = 1_700_000_000_000
    static let defaultDevice: [String: Any] = [
        "platform": "android",
        "os_version": "14",
        "app_version": "4.2.0",
        "sdk_version": "2.0.2",
        "locale": "en-IN",
    ]

    private let file: String
    private let json: [String: Any]
    private var now = World.startMs
    private var sessionCount = 1
    private var sessionId: String { "s\(sessionCount)" }

    private var specs: [String: [String: Any]] = [:]
    private var campaigns: [CampaignModel] = []
    private var index = TriggerIndex([])
    private var audience: Set<String> = []
    private var frequency: [String: FrequencyState] = [:]
    private var slots: [String: String] = [:]
    var attributes: [String: Any] = [:]
    var device: [String: Any] = World.defaultDevice
    private var routerDrops: Set<String> = []
    private var screen = ""
    private var lastSignal: RuleSignal?
    private var routed: [(CampaignModel, RuleSignal)] = []
    private var engine: DecisionEngine!
    private var sink: RecordSink!

    private final class RecordSink: DiagnosticSink, @unchecked Sendable {
        var records: [TimelineRecord] = []
        func accepts(_ record: TimelineRecord) -> Bool { true }
        func emit(_ record: TimelineRecord) { records.append(record) }
    }

    init(file: String, json: [String: Any]) {
        self.file = file
        self.json = json
    }

    // MARK: run

    func run() -> [String] {
        var fatal: [String] = []
        let raw = (json["campaigns"] as? [[String: Any]]) ?? []
        for spec in raw {
            guard let key = spec["key"] as? String else {
                fatal.append("campaign without a key")
                continue
            }
            specs[key] = spec
            if spec["inAudience"] as? Bool == true { audience.insert(key) }
        }
        // The campaigns reach the engine the way a fetched bundle's do: through
        // the bundle parser the SDK runs on a network response.
        let bundle = CampaignBundle.create(
            rawCampaigns: raw.map(campaignJSON), designTokensJSON: nil)
        campaigns = bundle.campaigns
        for key in specs.keys where !campaigns.contains(where: { $0.campaignKey == key }) {
            fatal.append("campaign \(key) was dropped by the bundle parser")
        }
        if !fatal.isEmpty { return fatal }
        index = TriggerIndex(campaigns)

        if let context = json["context"] as? [String: Any] {
            applyContext(context)
        }
        if let drops = json["routerDrops"] as? [String] {
            routerDrops = Set(drops)
        }
        if let history = (json["context"] as? [String: Any])?["frequencyHistory"] as? [String: Any] {
            for (key, value) in history {
                guard let h = value as? [String: Any] else { continue }
                frequency[key] = FrequencyState(
                    total: (h["total"] as? NSNumber)?.intValue ?? 0,
                    windowCount: (h["windowCount"] as? NSNumber)?.intValue ?? 0,
                    windowAnchorAt: (h["windowAnchorAgoMs"] as? NSNumber).map {
                        Int64(now - $0.intValue)
                    },
                    sessionId: h["sessionId"] as? String,
                    stoppedAt: (h["stopped"] as? Bool) == true ? Int64(now) : nil)
            }
        }

        sink = RecordSink()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        engine = DecisionEngine(
            facts: self,
            route: { [weak self] campaign, _, signal in
                guard let self else { return }
                if self.routerDrops.contains(campaign.campaignKey) { throw RouterDropped() }
                self.routed.append((campaign, signal))
                if let slot = campaign.inlineSlotKey { self.slots[slot] = campaign.campaignKey }
                if let policy = campaign.frequency {
                    self.frequency[campaign.campaignKey] = FrequencyEvaluator.recordShow(
                        policy, self.frequency[campaign.campaignKey],
                        Int64(self.now), self.sessionId)
                }
            },
            nowMs: { [weak self] in self?.now ?? World.startMs })
        engine.ready()

        var problems: [String] = []
        let steps = (json["steps"] as? [[String: Any]]) ?? []
        for (i, s) in steps.enumerated() {
            problems += runStep(i, s, count: steps.count)
        }
        engine.reset()
        return problems
    }

    // MARK: steps

    private func runStep(_ index: Int, _ step: [String: Any], count: Int) -> [String] {
        let routedBefore = routed.count
        let recordsBefore = sink.records.count

        if let advance = (step["advanceMs"] as? NSNumber)?.intValue, advance > 0 {
            now += advance
            // The waits compare `now` with the end they stored: moving the
            // injected clock, then scheduling, is the whole time travel.
            engine.waits.schedule()
        }
        if step["newSession"] as? Bool == true { sessionCount += 1 }
        switch step["lifecycle"] as? String {
        case "background": engine.pause()
        case "foreground": engine.resume()
        default: break
        }
        if step["endSession"] as? Bool == true { engine.reset() }
        if let drops = step["routerDrops"] as? [String] { routerDrops = Set(drops) }
        if let context = step["context"] as? [String: Any] { applyContext(context) }
        if let completed = step["completed"] as? String {
            frequency[completed] = FrequencyEvaluator.recordStop(
                frequency[completed], Int64(now))
        }
        var signal: RuleSignal?
        if let raw = step["signal"] as? [String: Any] {
            guard let parsed = makeSignal(raw) else {
                return ["step \(index + 1) of \(count): unknown signal \(raw)"]
            }
            signal = parsed
            lastSignal = parsed
            if case .screenViewed(let name) = parsed { screen = name }
            engine.send(parsed)
        }

        let shownNow = Array(routed[routedBefore...])
        let recordsNow = Array(sink.records[recordsBefore...])
        guard let expect = step["expect"] as? [String: Any] else {
            return ["step \(index + 1) of \(count): no expect block"]
        }
        var problems: [String] = []

        let overlays = shownNow.filter { $0.0.inlineSlotKey == nil }.map { $0.0.campaignKey }
        let inlines = shownNow.filter { $0.0.inlineSlotKey != nil }.map { $0.0.campaignKey }
        if expect.keys.contains("shown") {
            let want = expect["shown"] as? String
            let got = overlays.isEmpty ? "nothing" : overlays.joined(separator: ", ")
            if overlays != (want.map { [$0] } ?? []) {
                problems.append("shown: expected \(want ?? "nothing"), got \(got)")
            }
        }
        if let want = expect["inlineShown"] as? [String] {
            if inlines.sorted() != want.sorted() {
                problems.append("inlineShown: expected \(want), got \(inlines)")
            }
        }

        var actualVerdicts: [String: String] = [:]
        if let verdicts = expect["verdicts"] as? [String: Any] {
            if let evalSignal = signal ?? lastSignal {
                problems += checkVerdicts(verdicts, signal: evalSignal, actual: &actualVerdicts)
            } else {
                problems.append("verdicts need a signal in this or an earlier step")
            }
        }

        // The corpus speaks enum case names (`lowerPriority`), the spelling
        // Flutter and Android compare against, not wire strings. iOS reasons
        // carry both; match on the case name so the same behavior compares
        // equal on all three stacks.
        let heldCases: Set<String> = [
            "lowerPriority", "capped", "notInAudience", "notOnTargetScreen",
        ]
        if let want = expect["heldBack"] as? [String: String] {
            var got: [String: String] = [:]
            for record in recordsNow where record.campaignKey != nil {
                let name = reasonName(record.reason)
                if heldCases.contains(name) { got[record.campaignKey!] = name }
            }
            if got != want {
                problems.append("heldBack: expected \(want), got \(got)")
            }
        }
        func keysOf(_ wire: String) -> [String] {
            recordsNow.filter { $0.reason?.wire == wire }.compactMap { $0.campaignKey }.sorted()
        }
        if let want = expect["waiting"] as? [String] {
            let got = keysOf("wait_started")
            if got != want.sorted() {
                problems.append("waiting (started a wait): expected \(want), got \(got)")
            }
        }
        if let want = expect["waitCancelled"] as? [String] {
            let got = keysOf("wait_cancelled")
            if got != want.sorted() {
                problems.append("waitCancelled: expected \(want), got \(got)")
            }
        }
        if let want = expect["waitCancelCauses"] as? [String: String] {
            var got: [String: String] = [:]
            for record in recordsNow
                where record.reason?.wire == "wait_cancelled" && record.campaignKey != nil
            {
                got[record.campaignKey!] = record.extras["cause"] ?? ""
            }
            if got != want {
                problems.append("waitCancelCauses: expected \(want), got \(got)")
            }
        }
        if expect.keys.contains("rendered") {
            if shownNow.count != 1 {
                problems.append(
                    "rendered: expected exactly one campaign shown, got \(shownNow.count)")
            } else {
                let (campaign, shownBy) = shownNow[0]
                if let text = (specs[campaign.campaignKey]?["render"] as? [String: Any])?["text"]
                    as? String
                {
                    let got = render(campaign, text: text, signal: shownBy)
                    if got != (expect["rendered"] as? String) {
                        problems.append(
                            "rendered: expected \"\(expect["rendered"] as? String ?? "?")\", "
                                + "got \"\(got)\" (template \"\(text)\")")
                    }
                } else {
                    problems.append("rendered: \(campaign.campaignKey) has no render.text")
                }
            }
        }

        if problems.isEmpty { return [] }
        let shownLine = shownNow.isEmpty ? "nothing" : shownNow.map { $0.0.campaignKey }.joined(separator: ", ")
        let advanced = (step["advanceMs"] as? NSNumber)?.intValue ?? 0
        var detail = [
            "step \(index + 1) of \(count)"
                + (step["signal"] != nil ? " (signal \(step["signal"]!))" : "")
                + (advanced > 0 ? " (advance \(advanced)ms)" : ""),
        ]
        detail += problems.map { "  - \($0)" }
        detail.append("  routed this step: \(shownLine)")
        if !actualVerdicts.isEmpty { detail.append("  verdicts: \(actualVerdicts)") }
        detail.append("  attributes: \(attributes)")
        detail.append("  engine log this step:")
        for record in recordsNow {
            detail.append("    \(record.campaignKey ?? "-") \(record.reason?.wire ?? "") \(record.message)")
        }
        return [detail.joined(separator: "\n")]
    }

    private func checkVerdicts(
        _ verdicts: [String: Any], signal evalSignal: RuleSignal,
        actual actualVerdicts: inout [String: String]
    ) -> [String] {
        var problems: [String] = []
        for (key, value) in verdicts {
            guard let campaign = campaigns.first(where: { $0.campaignKey == key }),
                  let rule = campaign.rule
            else {
                problems.append("verdicts: unknown campaign \(key)")
                continue
            }
            let verdict = RuleEvaluator.evaluate(
                rule, evalSignal, attributes: attributes, device: device)
            let actual: String = switch verdict.kind {
            case .eligible: "eligible"
            case .notTriggered: "not_triggered"
            case .ineligible: "ineligible"
            }
            actualVerdicts[key] = actual
            guard let want = value as? [String: Any] else {
                problems.append("verdicts: \(key) is not an object")
                continue
            }
            if want["verdict"] as? String != actual {
                problems.append(
                    "verdict of \(key): expected \(want["verdict"] as? String ?? "?"), "
                        + "got \(actual) (reason \(verdict.reason?.wire ?? "none"), "
                        + "detail \(verdict.detail ?? "none"))")
            } else if let wantReason = want["reason"] as? String {
                if wantReason != (verdict.reason?.wire ?? "") {
                    problems.append(
                        "reason of \(key): expected \(wantReason), "
                            + "got \(verdict.reason?.wire ?? "none")")
                }
            } else if verdict.reason != nil {
                problems.append(
                    "reason of \(key): expected none, got \(verdict.reason!.wire)")
            }
        }
        return problems
    }

    private func applyContext(_ context: [String: Any]) {
        if let attributes = context["attributes"] as? [String: Any] {
            self.attributes = attributes
        }
        if let device = context["device"] as? [String: Any] {
            self.device = device
        }
    }

    private func makeSignal(_ json: [String: Any]) -> RuleSignal? {
        let name = json["name"] as? String ?? ""
        let properties = (json["properties"] as? [String: Any]) ?? [:]
        switch json["type"] as? String {
        case "app_opened": return .appOpened
        case "screen_viewed": return .screenViewed(name)
        case "event": return .event(name, properties)
        case "app_foregrounded": return .appForegrounded
        case "anchor_visible": return .anchorVisible(name)
        case "slot_visible": return .slotVisible(name)
        default: return nil
        }
    }

    /// The copy as the SDK builds it for a self-triggered campaign: attributes,
    /// then bound context variables.
    private func render(_ campaign: CampaignModel, text: String, signal: RuleSignal) -> String {
        var eventProperties: [String: Any] = [:]
        if case .event(_, let properties) = signal { eventProperties = properties }
        var cepVars: [String: String] = [:]
        for (key, value) in attributes { cepVars[key] = "\(value)" }
        for (key, value) in bindContextVariables(
            campaign.variableSchemas,
            userAttributes: attributes,
            eventProperties: eventProperties)
        {
            cepVars[key] = value
        }
        let context = buildVariableContext(schemas: campaign.variableSchemas, cepVars: cepVars)
        return interpolate(text, context: context)
    }

    // MARK: DecisionFacts

    var ready: Bool { true }

    func listeningTo(_ signal: RuleSignal) -> [CampaignModel] {
        index.listeningTo(signal)
    }

    func find(_ campaignKey: String) -> CampaignModel? {
        campaigns.first { $0.campaignKey == campaignKey }
    }

    var audienceContext: String { "case" }

    func inAudience(_ campaign: CampaignModel) -> Bool {
        campaign.allowsUser(Array(audience))
    }

    func capped(_ campaign: CampaignModel) -> Bool {
        guard let policy = campaign.frequency else { return false }
        return !FrequencyEvaluator.evaluate(
            policy, frequency[campaign.campaignKey], Int64(now), sessionId,
            unseenCountsAsZero: campaign.rule != nil
        ).allow
    }

    var currentScreen: String { screen }

    func slotCampaignKey(_ slot: String) -> String? { slots[slot] }
}

/// An emitted reason's enum case name (`lowerPriority`), the spelling the
/// shared corpus compares against. Verdict `reason` fields and wait-cancel
/// `cause` extras stay on wire strings, which the corpus already uses.
private func reasonName(_ reason: (any DiagnosticReason)?) -> String {
    guard let reason else { return "" }
    return "\(reason)"
}

/// A campaign as the bundle sends it: the case's `rule`, `frequency`,
/// `audienceGated` and `templateConfig` variables around a minimal valid nudge
/// (overlay) or banner (inline) template.
///
/// One iOS mapping the SDK dialect needs: the engine reads screens from the
/// campaign's `targetScreenNames`, not from `rule.screens`, so the corpus
/// `rule.screens` list is projected there. The rule itself passes through
/// untouched, malformed or not.
private func campaignJSON(_ spec: [String: Any]) -> [String: Any] {
    let key = spec["key"] as? String ?? ""
    let inline = spec["kind"] as? String == "inline"
    let template = (spec["templateConfig"] as? [String: Any]) ?? [:]
    var body: [String: Any] = inline
        ? [
            "templateType": "banner",
            "slotKey": spec["slot"] as? String ?? "slot_\(key)",
            "image": ["url": "https://cdn.example.com/a.png"],
        ]
        : [
            "templateType": "nudge",
            "layoutMode": "canvas",
            "container": ["displayType": "dialog"],
            "canvas": [
                "version": 2,
                "canvasWidth": 320,
                "canvasHeight": 200,
                "children": [] as [Any],
            ],
            "variables": [] as [Any],
        ]
    for (k, v) in template { body[k] = v }
    var out: [String: Any] = [
        "id": "id-\(key)",
        "campaignKey": key,
        "campaignType": inline ? "inline" : "nudge",
        "status": "active",
        "audienceGated": spec["audienceGated"] as? Bool == true,
        "templateConfig": body,
    ]
    if let rule = spec["rule"] { out["rule"] = rule }
    if let frequency = spec["frequency"] { out["frequency"] = frequency }
    if let screens = (spec["rule"] as? [String: Any])?["screens"] as? [String] {
        out["targetScreenNames"] = ["names": screens]
    }
    return out
}
