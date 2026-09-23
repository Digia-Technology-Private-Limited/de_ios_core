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
    private let deviceIdProvider: DeviceIdProvider?
    private let identityStorage: LocalStorage
    private let lock = NSLock()

    init(
        config: DigiaConfig? = nil,
        deviceIdProvider: DeviceIdProvider? = nil,
        storage: LocalStorage = UserDefaultsLocalStorage().scoped("identity")
    ) {
        self.config = config
        self.deviceIdProvider = deviceIdProvider
        self.identityStorage = storage
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
            userId: userId
        )
        let resolvedDeviceId = deviceIdProvider?.deviceId ?? resolveDeviceId()
        Task.detached { await Self.post(config: currentConfig, deviceId: resolvedDeviceId, body: body) }
    }

    // MARK: - Networking

    private static func post(config: DigiaConfig, deviceId: String, body: [String: Any]) async {
        guard let url = endpoint() else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-digia-project-id")
        request.setValue(deviceId, forHTTPHeaderField: "x-digia-device-id")
        request.timeoutInterval = 10
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                log.e("Survey submission post failed (status=\(http.statusCode))")
            }
        } catch {
            log.e("Survey submission post failed", error: error)
        }
    }

    private static func endpoint() -> URL? {
        URL(string: DigiaEndpoints.submission)
    }

    private func resolveDeviceId() -> String {
        if let saved = identityStorage.string(forKey: "device_id"), !saved.isEmpty {
            return saved
        }
        if let anon = identityStorage.string(forKey: "anonymous_id"), !anon.isEmpty {
            identityStorage.set(anon, forKey: "device_id")
            return anon
        }
        #if canImport(UIKit)
        let idfv: String?
        if Thread.isMainThread {
            idfv = MainActor.assumeIsolated { UIDevice.current.identifierForVendor?.uuidString }
        } else {
            idfv = DispatchQueue.main.sync { UIDevice.current.identifierForVendor?.uuidString }
        }
        #else
        let idfv: String? = nil
        #endif
        let id = idfv ?? UUID().uuidString
        identityStorage.set(id, forKey: "device_id")
        identityStorage.set(id, forKey: "anonymous_id")
        return id
    }

    // MARK: - Body

    static func buildBody(
        campaignId: String,
        survey: SurveyConfigModel,
        answers: [String: SurveyAnswer],
        startedAt: Date,
        now: Date,
        userId: String?
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
