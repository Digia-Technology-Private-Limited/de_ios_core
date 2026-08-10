import Foundation

internal enum CaptureRefusal: Equatable, Sendable {
    case notDebugBuild
    case captureModeDisabled
    case pageIdentityMissing
    case offline
    case explicitActionRequired
    case alreadyInFlight
}

internal enum CaptureUploadRejection: Equatable, Sendable {
    case invalidEnvelope
    case pngTooLarge
    case server(status: Int)
    case invalidResponse
    case transportFailed
}

internal enum CaptureUploadResult: Equatable, Sendable {
    case accepted(assetId: String)
    case rejected(CaptureUploadRejection)
}

@MainActor
internal protocol CaptureUploader: AnyObject {
    func upload(
        envelope: PageCaptureEnvelopeV1,
        png: Data
    ) async -> CaptureUploadResult
}

internal struct CaptureGateState: Equatable, Sendable {
    internal let isDebugBuild: Bool
    internal let captureModeEnabled: Bool
    internal let pageKey: String?
    internal let connectivityAvailable: Bool
    internal let explicitAction: Bool

    internal init(
        isDebugBuild: Bool = true,
        captureModeEnabled: Bool = true,
        pageKey: String? = "home",
        connectivityAvailable: Bool = true,
        explicitAction: Bool = true
    ) {
        self.isDebugBuild = isDebugBuild
        self.captureModeEnabled = captureModeEnabled
        self.pageKey = pageKey
        self.connectivityAvailable = connectivityAvailable
        self.explicitAction = explicitAction
    }
}

internal enum CaptureSessionResult: Equatable, Sendable {
    case uploaded(CaptureUploadResult)
    case refused(CaptureRefusal)
}

@MainActor
internal final class CaptureSession {
    private let gates: CaptureGateState
    private let uploader: CaptureUploader
    private(set) internal var isCaptureInFlight = false

    internal init(gates: CaptureGateState, uploader: CaptureUploader) {
        self.gates = gates
        self.uploader = uploader
    }

    internal func capture(
        envelope: PageCaptureEnvelopeV1,
        png: Data
    ) async -> CaptureSessionResult {
        guard gates.isDebugBuild else { return .refused(.notDebugBuild) }
        guard gates.captureModeEnabled else { return .refused(.captureModeDisabled) }
        guard let pageKey = gates.pageKey, !pageKey.isEmpty, pageKey == envelope.pageKey else {
            return .refused(.pageIdentityMissing)
        }
        guard gates.connectivityAvailable else { return .refused(.offline) }
        guard gates.explicitAction else { return .refused(.explicitActionRequired) }
        guard !isCaptureInFlight else { return .refused(.alreadyInFlight) }

        isCaptureInFlight = true
        defer { isCaptureInFlight = false }
        return .uploaded(await uploader.upload(
            envelope: envelope,
            png: png
        ))
    }
}
