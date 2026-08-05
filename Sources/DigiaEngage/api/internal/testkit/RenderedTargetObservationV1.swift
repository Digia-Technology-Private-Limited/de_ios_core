import CoreGraphics
import CryptoKit
import Foundation

enum RenderedTargetApproachV1: String, Codable, Equatable {
    case registered
    case semantic
    case geometry
    case assisted
}

enum RenderedTargetOutcomeV1: String, Codable, Equatable {
    case presented
    case updated
    case failed
}

struct RenderedTargetFrameLogicalV1: Codable, Equatable {
    let left: Double
    let top: Double
    let right: Double
    let bottom: Double

    init(_ rect: CGRect) {
        left = Double(rect.minX)
        top = Double(rect.minY)
        right = Double(rect.maxX)
        bottom = Double(rect.maxY)
    }
}

struct RenderedTargetObservationV1: Codable, Equatable {
    let observationVersion: Int
    let runId: String
    let platform: String
    let approach: RenderedTargetApproachV1
    let stepId: String
    let sequence: Int
    let monotonicTimeNs: String
    let frameLogical: RenderedTargetFrameLogicalV1
    let paddingLogical: Double
    let outcome: RenderedTargetOutcomeV1
    let failureCode: String?
}

enum TestKitNativeEvidenceErrorV1: Error, Equatable {
    case invalidRunId
    case runIdMismatch
}

final class RenderedTargetObservationStoreV1: @unchecked Sendable {
    static let shared = RenderedTargetObservationStoreV1()

    private let capacity: Int
    private let clock: () -> UInt64
    private let lock = NSLock()
    private var runId: String?
    private var nextSequence = 1
    private var observations: [RenderedTargetObservationV1] = []

    init(capacity: Int = 500, clock: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.clock = clock
    }

    func setRunId(_ runId: String) throws {
        guard Self.isSafeRunId(runId) else { throw TestKitNativeEvidenceErrorV1.invalidRunId }
        lock.lock()
        self.runId = runId
        nextSequence = 1
        observations.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        runId = nil
        nextSequence = 1
        observations.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    func matches(runId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.runId == runId
    }

    func record(
        approach: RenderedTargetApproachV1,
        stepId: String,
        frameLogical: CGRect,
        paddingLogical: Double,
        failureCode: String?
    ) {
        lock.lock()
        guard let runId else {
            lock.unlock()
            return
        }

        let hasSuccessfulStepObservation = observations.contains {
            $0.stepId == stepId && $0.outcome != .failed
        }
        let outcome: RenderedTargetOutcomeV1 = if failureCode != nil {
            .failed
        } else if hasSuccessfulStepObservation {
            .updated
        } else {
            .presented
        }
        let observation = RenderedTargetObservationV1(
            observationVersion: 1,
            runId: runId,
            platform: "ios",
            approach: approach,
            stepId: stepId,
            sequence: nextSequence,
            monotonicTimeNs: String(clock()),
            frameLogical: RenderedTargetFrameLogicalV1(frameLogical),
            paddingLogical: paddingLogical,
            outcome: outcome,
            failureCode: failureCode
        )
        nextSequence += 1
        if observations.count == capacity { observations.removeFirst() }
        observations.append(observation)
        lock.unlock()
    }

    func snapshot(runId: String) -> [RenderedTargetObservationV1] {
        lock.lock()
        defer { lock.unlock() }
        guard self.runId == runId else { return [] }
        return observations
    }

    private static func isSafeRunId(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128, value.first?.isLetter == true || value.first?.isNumber == true else {
            return false
        }
        return value.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
    }
}

final class TestKitNativeEvidenceExporterV1 {
    private let observationStore: RenderedTargetObservationStoreV1
    private let assistedTraces: () -> [AssistedGeometryTraceV1]
    private let baseDirectory: URL

    init(
        observationStore: RenderedTargetObservationStoreV1 = .shared,
        assistedTraces: @escaping () -> [AssistedGeometryTraceV1] = {
            AssistedGeometryRuntimeV1.diagnostics.snapshot()
        },
        baseDirectory: URL? = nil
    ) {
        self.observationStore = observationStore
        self.assistedTraces = assistedTraces
        self.baseDirectory = baseDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("digia-testkit", isDirectory: true)
    }

    func export(runId: String) throws -> URL {
        guard observationStore.matches(runId: runId) else {
            throw TestKitNativeEvidenceErrorV1.runIdMismatch
        }

        let observationsData = try JSONEncoder().encode(observationStore.snapshot(runId: runId))
        let observations = try JSONSerialization.jsonObject(with: observationsData)
        let payload: [String: Any] = [
            "exportVersion": 1,
            "renderedTargetObservations": observations,
            "assistedGeometryTraces": assistedTraces().map(Self.traceJson),
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let digest = SHA256.hash(data: payloadData).map { String(format: "%02x", $0) }.joined()
        let envelope: [String: Any] = [
            "exportVersion": 1,
            "runId": runId,
            "platform": "ios",
            "payload": payload,
            "sha256": digest,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])

        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        let destination = baseDirectory.appendingPathComponent("assisted-\(runId).json")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private static func traceJson(_ trace: AssistedGeometryTraceV1) -> [String: Any] {
        var json: [String: Any] = [
            "outcome": trace.outcome,
            "warnings": trace.warnings.map(\.rawValue),
        ]
        json["campaignKey"] = trace.campaignKey
        json["stepId"] = trace.stepId
        json["variantId"] = trace.variantId
        json["captureId"] = trace.captureId
        json["failure"] = trace.failure?.rawValue
        if let rect = trace.roundedTargetPx {
            json["roundedTargetPx"] = [
                "left": rect.left,
                "top": rect.top,
                "right": rect.right,
                "bottom": rect.bottom,
            ]
        }
        return json
    }
}
