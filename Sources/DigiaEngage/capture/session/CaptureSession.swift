// Module: capture/session
//
// Explicit capture gating and the uploader seam. This module owns no image
// encoding or HTTP; it only decides whether a caller's one deliberate capture
// action may cross into capture/transport.

import Foundation

internal enum CaptureRefusal: Equatable, Sendable {
    case notDebugBuild
    case syncDisabled
    case captureModeDisabled
    case pairingMissing
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
    case accepted(captureId: String)
    case duplicate(captureId: String)
    case rejected(CaptureUploadRejection)
}

/// The single transport seam shared by capture/session and capture/transport.
/// The PNG is an argument for the duration of the upload only; the session never
/// stores it, queues it, retries it, or writes it to disk.
@MainActor
internal protocol CaptureUploader: AnyObject {
    func upload(
        envelope: PageCaptureEnvelopeV1,
        png: Data,
        pairingToken: String
    ) async -> CaptureUploadResult
}

internal struct CaptureGateState: Equatable, Sendable {
    internal let isDebugBuild: Bool
    internal let syncEnabled: Bool
    internal let captureModeEnabled: Bool
    internal let pairingToken: String?
    internal let pageKey: String?
    internal let connectivityAvailable: Bool
    internal let explicitAction: Bool

    internal init(
        isDebugBuild: Bool = true,
        syncEnabled: Bool = true,
        captureModeEnabled: Bool = true,
        pairingToken: String? = "paired",
        pageKey: String? = "home",
        connectivityAvailable: Bool = true,
        explicitAction: Bool = true
    ) {
        self.isDebugBuild = isDebugBuild
        self.syncEnabled = syncEnabled
        self.captureModeEnabled = captureModeEnabled
        self.pairingToken = pairingToken
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
        guard gates.syncEnabled else { return .refused(.syncDisabled) }
        guard gates.captureModeEnabled else { return .refused(.captureModeDisabled) }
        guard let pairingToken = gates.pairingToken, !pairingToken.isEmpty else {
            return .refused(.pairingMissing)
        }
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
            png: png,
            pairingToken: pairingToken
        ))
    }
}
