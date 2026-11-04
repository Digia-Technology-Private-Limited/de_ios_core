import Foundation

/// Reports the active survey's lifecycle as the renderer walks it. Each call
/// fires the matching experience event to the CEP and to Digia analytics.
///
/// Moved verbatim from `SDKInstance` (survey lifecycle section); only the
/// receiver changed. Mirrors Flutter's `SurveyReporter` (PR #253).
///
/// CEP plugin sees: Impressed (started), Dismissed (every teardown — closed
/// without finishing AND completed; all routed through markSurveyDismissed).
/// Internal analytics sees: Answered, Completed.
@MainActor
final class SurveyReporter {
    init(_ ctx: SurfaceContext, _ orchestrator: SurveyOrchestrator) {
        self.ctx = ctx
        self.orchestrator = orchestrator
    }

    private let ctx: SurfaceContext
    private let orchestrator: SurveyOrchestrator

    /// Guards double-firing the survey `Completed` event for one showing.
    private var completedSurveyToken: Int64?

    /// Survey whose start-engagement ("welcome_start") click has already fired
    /// (once per showing).
    private var welcomeStartToken: Int64?

    /// Per-question viewed-at timestamps, keyed by "<surveyToken>:<nodeId>".
    /// Used to compute `time_to_answer_ms` on QuestionAnswered.
    private var questionViewedAt: [String: Date] = [:]

    /// Fired once when the survey first becomes visible (treated as an impression).
    func reportSurveyStarted() {
        guard let state = orchestrator.state else { return }
        ctx.impressed(
            state.payload,
            campaignKey: state.payload.campaignKey,
            viewed: SurveyEvent.Viewed(
                itemTotal: state.config.questionCount,
                hasWelcome: state.config.hasWelcome,
                hasThanks: state.config.hasThanks,
                hasBranching: state.config.hasBranching,
                screenName: ctx.currentScreen
            )
        )
    }

    /// The survey's start engagement — fired once per showing. When a welcome
    /// screen is present this is its "Start" CTA tap; when there's no welcome
    /// screen it is raised on the first continue (see `reportSurveyAnswered` /
    /// `reportSurveyQuestionSkipped`).
    func reportSurveyWelcomeStart() {
        guard let state = orchestrator.state else { return }
        if welcomeStartToken == state.token { return }
        welcomeStartToken = state.token
        ctx.events.toDigia(SurveyEvent.Clicked(elementId: "welcome_start"), payload: state.payload)
    }

    func reportSurveyStartClicked() {
        guard let state = orchestrator.state else { return }
        ctx.events.clicked(payload: state.payload, elementId: "welcome_start")
    }

    /// When no welcome screen exists, the first continue is the start engagement.
    private func ensureWelcomeStartIfNoWelcome(_ state: ActiveSurveyState) {
        if !state.config.hasWelcome { reportSurveyWelcomeStart() }
    }

    /// A survey question became visible. `itemIndex` is its 1-based shown position.
    func reportSurveyQuestionViewed(nodeId: String, itemIndex: Int) {
        guard let state = orchestrator.state else { return }
        guard let block = state.config.blockForNode(nodeId) else { return }
        if block.type.isContent { return }
        questionViewedAt[Self.questionKey(token: state.token, nodeId: nodeId)] = Date()
        let typeWire = block.type.rawValue
        ctx.events.toDigia(
            SurveyEvent.QuestionViewed(
                questionId: nodeId,
                questionTitle: Self.questionTitle(block),
                questionType: typeWire,
                itemIndex: itemIndex,
                itemTotal: state.config.questionCount,
                blockType: typeWire,
                blockId: block.id,
                isRequired: block.required
            ),
            payload: state.payload
        )
    }

    /// An eligible optional question was skipped (advanced without an answer).
    func reportSurveyQuestionSkipped(nodeId: String, itemIndex: Int) {
        guard let state = orchestrator.state else { return }
        // No welcome-start Clicked here: a skip is not an engagement with the survey, as on Flutter. Only an
        // answer stands in for the missing welcome's Start.
        guard let block = state.config.blockForNode(nodeId) else { return }
        questionViewedAt.removeValue(forKey: Self.questionKey(token: state.token, nodeId: nodeId))
        ctx.events.toDigia(
            SurveyEvent.QuestionSkipped(
                questionId: nodeId,
                questionTitle: Self.questionTitle(block),
                itemIndex: itemIndex,
                blockType: block.type.rawValue,
                blockId: block.id),
            payload: state.payload
        )
    }

    /// Fired each time the user answers a question (one event per answered question).
    func reportSurveyAnswered(stepId: String, answer: [String: JSONValue]) {
        guard let state = orchestrator.state else { return }
        ensureWelcomeStartIfNoWelcome(state)
        let block = state.config.blockForNode(stepId)
        let values = Self.stringArray(answer["values"])
        let viewedKey = Self.questionKey(token: state.token, nodeId: stepId)
        let timeToAnswerMs: Int64? = questionViewedAt[viewedKey].map {
            Int64(Date().timeIntervalSince($0) * 1000)
        }
        questionViewedAt.removeValue(forKey: viewedKey)
        let scaleBounds = block.flatMap(Self.scaleBounds)
        let typeWire = block?.type.rawValue
        let openEnded = block.map { Self.openEndedQuestionTypes.contains($0.type) } ?? false
        var sanitizedAnswer = answer
        sanitizedAnswer.removeValue(forKey: "comment")
        let answerValue: String? = openEnded ? nil : values.first
        let answerText: String? = openEnded ? nil : (values.isEmpty ? nil : values.joined(separator: ", "))
        let answerLabel: String? = openEnded ? nil : block.flatMap { Self.answerLabel(block: $0, values: values) }
        let answerOptions: [String]? = openEnded ? nil : (values.count > 1 ? values : nil)
        ctx.events.toDigia(
            SurveyEvent.QuestionAnswered(
                questionId: stepId,
                questionTitle: block.flatMap(Self.questionTitle),
                questionType: typeWire,
                answerValue: answerValue,
                answerText: answerText,
                blockType: typeWire,
                blockId: block?.id,
                answerLabel: answerLabel,
                answerOptions: answerOptions,
                scaleMin: scaleBounds?.min,
                scaleMax: scaleBounds?.max,
                timeToAnswerMs: timeToAnswerMs,
                answer: openEnded ? [:] : Self.foundation(sanitizedAnswer)
            ),
            payload: state.payload
        )
    }

    func markSurveyCompleted(response: [String: JSONValue], answers: [String: SurveyAnswer] = [:]) {
        reportSurveyCompleted(response: response, answers: answers)
        markSurveyDismissed()
    }

    func reportSurveyCompleted(response: [String: JSONValue], answers: [String: SurveyAnswer] = [:]) {
        guard let state = orchestrator.state else {
            ctx.sdk.logVerbose("reportSurveyCompleted: skip — no active survey state")
            return
        }
        if completedSurveyToken == state.token {
            ctx.sdk.logVerbose("reportSurveyCompleted: skip — already reported for token=\(state.token)")
            return
        }
        completedSurveyToken = state.token
        let isLiveTest = isLiveTestCepId(state.payload.cepCampaignId)

        // Permanent stop on "Digia Experience Completed" when stopOn is set.
        if !isLiveTest {
            ctx.recordCompleted(
                campaignKey: state.payload.campaignKey,
                cepCampaignId: state.payload.cepCampaignId)
        }

        // Analytics "Completed" fires once per survey showing, regardless of
        // whether a submission is reported to the backend below.
        let answeredCount = answers.isEmpty ? response.count : answers.count
        ctx.events.toDigia(
            SurveyEvent.Completed(
                itemTotal: state.config.questionCount,
                answeredCount: answeredCount,
                timeToCompleteMs: Int64(Date().timeIntervalSince(state.startedAt) * 1000),
                response: Self.foundation(response)
            ),
            payload: state.payload
        )

        if answers.isEmpty {
            ctx.sdk.logVerbose("reportSurveyCompleted: skip submission — no answers")
            return
        }
        if isLiveTest {
            relayLiveTestSubmission(state: state, answers: answers)
            return
        }
        guard ctx.sdk.config != nil else {
            ctx.sdk.logVerbose(
                "reportSurveyCompleted: skip submission — SDK not initialized (config is nil)")
            return
        }
        guard let campaignId = ctx.sdk.campaignStore.find(state.payload.campaignKey)?.id else {
            ctx.sdk.logVerbose(
                "reportSurveyCompleted: skip submission — no campaign for key '\(state.payload.campaignKey)'"
            )
            return
        }
        ctx.sdk.logVerbose(
            "reportSurveyCompleted: submitting campaignId=\(campaignId) answers=\(answers.count)")
        ctx.services?.submissionReporter.report(
            campaignId: campaignId,
            campaignKey: state.payload.campaignKey,
            survey: state.config,
            answers: answers,
            startedAt: state.startedAt,
            userId: ctx.services?.identityManager.userId
        )
    }

    /// Sends a live-tested survey's answers to the dashboard that asked for
    /// the test, through the live-only event passthrough (§2.3) rather than
    /// the real submission endpoint — one person pressing buttons during a
    /// test is not a respondent, and nothing here is stored.
    ///
    /// Built by the *same* `buildBody` the real submission uses, so what a PM
    /// reads during a test is the structure analytics would have recorded —
    /// not a second shape that can quietly drift from it.
    private func relayLiveTestSubmission(state: ActiveSurveyState, answers: [String: SurveyAnswer]) {
        guard let invocationId = testInvocationIdOf(state.payload.cepCampaignId) else { return }
        // Live-test campaigns are parsed on the spot and never added to
        // `campaignStore` — its own `id` (not the store's) is the only one in
        // scope here.
        guard let campaign = ctx.sdk.liveTestCampaigns[state.payload.cepCampaignId] else { return }
        let body = SurveySubmissionReporter.buildBody(
            campaignId: campaign.id,
            survey: state.config,
            answers: answers,
            startedAt: state.startedAt,
            now: Date(),
            userId: nil
        )
        guard let payload = body["payload"], let computed = body["computed"] else { return }
        ctx.sdk.logVerbose(
            "Live test submission relayed (answers=\(answers.count), invocationId=\(invocationId))")
        ctx.sdk.liveTestService.ackReporter.postEvent(
            invocationId,
            type: "survey_submission",
            payload: ["payload": payload, "computed": computed]
        )
    }

    func dismissCompletedSurvey() {
        markSurveyDismissed()
    }

    /// Clears per-showing guards, for tests.
    func resetForTesting() {
        completedSurveyToken = nil
        welcomeStartToken = nil
        questionViewedAt.removeAll()
    }

    func markSurveyDismissed(
        abandonedAtItem: Int? = nil,
        answeredCount: Int? = nil,
        reason: DismissReason = .userClose
    ) {
        guard let state = orchestrator.state else { return }
        let completed = completedSurveyToken == state.token
        let reason = completed ? DismissReason.completed : reason
        orchestrator.dismiss()
        ctx.events.toBoth(
            .dismissed(reason: reason, completed: completed),
            SurveyEvent.Dismissed(
                dismissReason: reason.wire,
                abandonedAtItem: completed ? nil : abandonedAtItem,
                itemTotal: state.config.questionCount,
                answeredCount: answeredCount,
                dwellMs: ctx.dwell.consumeDwellMs(state.payload.cepCampaignId)
            ),
            payload: state.payload
        )
        clearQuestionViewedAt(token: state.token)
    }

    func clearQuestionViewedAt(token: Int64) {
        let prefix = "\(token):"
        questionViewedAt = questionViewedAt.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Survey answer derivations (mirror Android's SurveyConfig helpers)

    /// Converts a `JSONValue` map to a Foundation map for JSON serialization,
    /// dropping `null` entries.
    private static func foundation(_ map: [String: JSONValue]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in map {
            if let any = value.anyValue { result[key] = any }
        }
        return result
    }

    private static func stringArray(_ value: JSONValue?) -> [String] {
        guard case .array(let arr)? = value else { return [] }
        return arr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    /// The block's title text, or nil when empty (blank titles are not worth
    /// shipping over the wire).
    private static func questionTitle(_ block: SurveyBlock) -> String? {
        let title = block.title.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Comma-joined labels for the selected option ids on a choice block.
    /// Returns nil when the block has no options or no selection matches —
    /// (e.g. rating/nps/text inputs whose answer values aren't option ids).
    private static func answerLabel(block: SurveyBlock, values: [String]) -> String? {
        guard !values.isEmpty, !block.options.isEmpty else { return nil }
        let labels = values.compactMap { id in
            block.options.first { $0.id == id }?.label
        }
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: ", ")
    }

    /// Numeric scale bounds for scored blocks (Rating 1–5, NPS 0–10). Other
    /// block types have no scale.
    private static func scaleBounds(_ block: SurveyBlock) -> (min: Int, max: Int)? {
        switch block.type {
        case .rating: return (1, 5)
        case .nps, .npsEmoji, .npsSmiley: return (0, 10)
        default: return nil
        }
    }

    private static let openEndedQuestionTypes: Set<SurveyBlockType> = [
        .shortText, .longText, .number, .email, .date
    ]

    /// Stable per-question key for `questionViewedAt`. Scoped by survey token
    /// so a re-show of the same survey doesn't reuse a stale viewed-at.
    private static func questionKey(token: Int64, nodeId: String) -> String {
        "\(token):\(nodeId)"
    }
}
