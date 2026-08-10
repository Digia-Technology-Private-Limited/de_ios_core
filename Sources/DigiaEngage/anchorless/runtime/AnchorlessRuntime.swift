import Foundation

internal enum AnchorlessRuntimeOutcome: Sendable {
    case resolved(rect: ResolvedTargetRect, prepared: PreparedAnchorlessTarget)
    case failed(AnchorlessFailure)

    case unavailable

    internal var failure: AnchorlessFailure? {
        if case let .failed(failure) = self { return failure }
        return nil
    }

    internal var rect: ResolvedTargetRect? {
        if case let .resolved(rect, _) = self { return rect }
        return nil
    }
}

@MainActor
internal final class AnchorlessRuntime {
    private let snapshotProvider: SnapshotProvider
    private let deviceStateProvider: AnchorlessDeviceStateProvider
    private let diagnostics: (AnchorlessTrace) -> Void

    internal init(
        snapshotProvider: SnapshotProvider,
        deviceStateProvider: AnchorlessDeviceStateProvider,
        diagnostics: @escaping (AnchorlessTrace) -> Void
    ) {
        self.snapshotProvider = snapshotProvider
        self.deviceStateProvider = deviceStateProvider
        self.diagnostics = diagnostics
    }

    internal func resolve(steps: [AnchorlessJSONValue]) -> AnchorlessRuntimeOutcome {
        guard steps.count == 1 else {
            return dispatchFailure(.stepCountInvalid, AnchorlessTrace(
                phase: .prepare, failure: .stepCountInvalid
            ))
        }
        return resolve(target: steps[0])
    }

    internal func resolve(target: AnchorlessJSONValue) -> AnchorlessRuntimeOutcome {
        let prepared: PreparedAnchorlessTarget
        let preparation = AnchorlessSolver.prepare(target: target, platform: .ios)
        switch preparation {
        case let .rejected(failure, trace):
            return dispatchFailure(failure, trace)
        case let .prepared(value, _):
            prepared = value
        }

        if let gateFailure = AnchorlessEligibilityGate.evaluate(
            prepared: prepared,
            device: deviceStateProvider.currentDeviceState()
        ) {
            return dispatchFailure(gateFailure, AnchorlessTrace(
                phase: .gate,
                failure: gateFailure,
                assetId: prepared.assetId,
                pageKey: prepared.pageKey,
                horizontalFrame: prepared.horizontalFrame,
                verticalFrame: prepared.verticalFrame
            ))
        }

        // One atomic read, immediately before `resolve`, never re-read per axis.
        guard let snapshot = snapshotProvider.currentSnapshot() else {
            // No window to read. Not one of the thirteen codes, and no code is
            // invented for it — one codeless trace, and nothing is shown.
            diagnostics(AnchorlessTrace(
                phase: .resolve,
                assetId: prepared.assetId,
                pageKey: prepared.pageKey,
                horizontalFrame: prepared.horizontalFrame,
                verticalFrame: prepared.verticalFrame
            ))
            return .unavailable
        }

        switch AnchorlessSolver.resolve(prepared: prepared, snapshot: snapshot) {
        case let .failed(failure, trace):
            return dispatchFailure(failure, trace)
        case let .resolved(rect, trace):
            diagnostics(trace)
            return .resolved(rect: rect, prepared: prepared)
        }
    }

    private func dispatchFailure(
        _ failure: AnchorlessFailure,
        _ trace: AnchorlessTrace
    ) -> AnchorlessRuntimeOutcome {
        diagnostics(trace)
        return .failed(failure)
    }
}
