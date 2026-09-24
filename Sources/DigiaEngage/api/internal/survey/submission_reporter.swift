import Foundation
#if canImport(UIKit)
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()
#endif

/// Posts a completed-survey submission to the dashboard backend's
/// `engage/sdk/recordSubmission` endpoint. Fires once per `markSurveyCompleted`.
typealias SurveySubmissionReporter = SubmissionReporter

final class SubmissionReporter: @unchecked Sendable {
    private(set) var config: DigiaConfig?
    private let identityManager: IdentityManager
    private let sessionIdProvider: (@Sendable () -> String?)?
    private let lock = NSLock()

    private let networkClient: any NetworkClient

    init(
        config: DigiaConfig? = nil,
        identityManager: IdentityManager,
        sessionIdProvider: (@Sendable () -> String?)? = nil,
        networkClient: any NetworkClient
    ) {
        self.config = config
        self.identityManager = identityManager
        self.sessionIdProvider = sessionIdProvider
        self.networkClient = networkClient
    }

    func configure(config: DigiaConfig) {
        lock.lock()
        defer { lock.unlock() }
        self.config = config
    }

    func report(
        campaignId: String,
        survey: SurveyConfigModel,
        answers: [String: SurveyAnswer],
        startedAt: Date,
        userId: String?
    ) {
        lock.lock()
        let currentConfig = self.config
        lock.unlock()

        guard let currentConfig else {
            #if canImport(UIKit)
            log.e("Survey submission skipped — config is nil")
            #endif
            return
        }
        let body = Self.buildBody(
            campaignId: campaignId,
            survey: survey,
            answers: answers,
            startedAt: startedAt,
            now: Date(),
            userId: userId,
            sessionId: sessionIdProvider?()
        )
        let resolvedDeviceId = identityManager.deviceId
        let client = self.networkClient
        Task.detached { await Self.post(networkClient: client, config: currentConfig, deviceId: resolvedDeviceId, body: body) }
    }

    // MARK: - Networking

    private static func post(networkClient: any NetworkClient, config: DigiaConfig, deviceId: String, body: [String: Any]) async {
        guard let url = endpoint() else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            let request = NetworkRequest(
                url: url,
                method: .post,
                headers: [
                    "Content-Type": "application/json",
                    "x-digia-project-id": config.apiKey,
                    "x-digia-device-id": deviceId
                ],
                body: data,
                connectTimeout: 10,
                readTimeout: 10
            )
            let response = try await networkClient.execute(request: request)
            if !response.isSuccessful {
                log.e("Survey submission post failed (status=\(response.statusCode))")
            }
        } catch {
            log.e("Survey submission post failed", error: error)
        }
    }

    private static func endpoint() -> URL? {
        URL(string: DigiaEndpoints.submission)
    }

    // MARK: - Body

    static func buildBody(
        campaignId: String,
        survey: SurveyConfigModel,
        answers: [String: SurveyAnswer],
        startedAt: Date,
        now: Date,
        userId: String?,
        sessionId: String? = nil
    ) -> [String: Any] {
        let promptNodes = survey.nodes.filter { node in
            guard let block = survey.blockFor(node) else { return false }
            return !block.type.isContent
        }
        let answeredNodes = promptNodes.filter { answers[$0.id]?.isAnswered == true }

        let responses: [[String: Any]] = answeredNodes.compactMap { node in
            guard let block = survey.blockFor(node),
                  let answer = answers[node.id] else { return nil }
            return buildResponse(block: block, answer: answer)
        }

        var computed: [String: Any] = [
            "durationMs": Int(now.timeIntervalSince(startedAt) * 1000),
        ]
        if let bucket = npsBucket(survey: survey, answers: answers) {
            computed["npsBucket"] = bucket
        }

        let payload: [String: Any] = [
            "templateVersion": "v1",
            "completion": [
                "answeredCount": answeredNodes.count,
                "totalCount": promptNodes.count,
            ],
            "responses": responses,
        ]

        var body: [String: Any] = [
            "campaignId": campaignId,
            "submissionKey": "attempt-\(Int(now.timeIntervalSince1970 * 1000))",
            "submissionType": "survey",
            "payload": payload,
            "computed": computed,
            "occurredAt": isoTimestamp(now),
        ]
        if let userId { body["userId"] = userId }
        if let sessionId { body["sessionId"] = sessionId }
        return body
    }

    private static func buildResponse(block: SurveyBlock, answer: SurveyAnswer) -> [String: Any] {
        var obj: [String: Any] = [
            "blockId": block.id,
            "blockType": block.type.rawValue,
            "title": block.title.text,
        ]

        switch block.type {
        case .nps, .rating, .number:
            if let n = answer.asNumber() {
                if n.rounded() == n { obj["value"] = Int(n) } else { obj["value"] = n }
            } else {
                obj["value"] = answer.values.first ?? ""
            }
        case .multiSelect, .tierList, .upvote:
            obj["value"] = answer.values
            let labels = answer.values.compactMap { id in
                block.options.first(where: { $0.id == id })?.label
            }
            if !labels.isEmpty { obj["valueLabel"] = labels }
        case .singleSelect, .reaction, .thisOrThat:
            let v = answer.values.first ?? ""
            obj["value"] = v
            if let label = block.options.first(where: { $0.id == v })?.label {
                obj["valueLabel"] = label
            }
        default:
            obj["value"] = answer.values.first ?? ""
        }

        if let comment = answer.comment, !comment.isEmpty {
            obj["comment"] = comment
        }
        return obj
    }

    private static func npsBucket(survey: SurveyConfigModel, answers: [String: SurveyAnswer]) -> String? {
        guard let npsNode = survey.nodes.first(where: { survey.blockFor($0)?.type == .nps }),
              let score = answers[npsNode.id]?.asNumber() else { return nil }
        let s = Int(score)
        if s >= 9 { return "promoter" }
        if s >= 7 { return "passive" }
        return "detractor"
    }

    private static func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
