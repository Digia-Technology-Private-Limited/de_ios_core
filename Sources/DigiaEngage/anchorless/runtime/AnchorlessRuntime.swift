// Module: anchorless/runtime
//
// Atomic snapshot construction, the device-eligibility gate, and diagnostics
// dispatch. Native runtime contract §1, §6, §9.
//
// It owns no rule arithmetic, no semantic or native-view lookup, no canvas
// content, no actions and no analytics. It never references `capture/*` (ARCH-2)
// and never imports a presentation-host type (ARCH-3).
//
// Every failure fails closed: no impression, no dismissal, no completion, no
// user-visible error, one local trace.

import Foundation

internal enum AnchorlessRuntimeOutcome: Sendable {
    case resolved(rect: ResolvedTargetRect, prepared: PreparedAnchorlessTarget)
    case failed(AnchorlessFailure)

    /// Fail closed with **no** failure code.
    ///
    /// Reached only when there is no window to take a snapshot from. The contract's
    /// thirteen codes do not cover that state and this package invents no
    /// fourteenth: the outcome is strictly weaker than any named code, produces the
    /// same fail-closed behaviour, and is recorded as an open question in the MR.
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
    private let diagnostics: DiagnosticsSink

    internal init(
        snapshotProvider: SnapshotProvider,
        deviceStateProvider: AnchorlessDeviceStateProvider,
        diagnostics: DiagnosticsSink
    ) {
        self.snapshotProvider = snapshotProvider
        self.deviceStateProvider = deviceStateProvider
        self.diagnostics = diagnostics
    }

    /// The full runtime path: `prepare` → eligibility gate → atomic snapshot →
    /// `resolve`, dispatching one trace per outcome.
    ///
    /// - Parameter steps: the campaign's `steps` array as delivered. Exactly one
    ///   element is valid; anything else is `stepCountInvalid`.
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
        switch AnchorlessSolver.prepare(target: target, platform: .ios) {
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
                variantId: prepared.variantId,
                pageKey: prepared.pageKey,
                horizontalFrame: prepared.horizontalFrame,
                verticalFrame: prepared.verticalFrame
            ))
        }

        // One atomic read, immediately before `resolve`, never re-read per axis.
        guard let snapshot = snapshotProvider.currentSnapshot() else {
            // No window to read. Not one of the thirteen codes, and no code is
            // invented for it — one codeless trace, and nothing is shown.
            diagnostics.record(AnchorlessTrace(
                phase: .resolve,
                variantId: prepared.variantId,
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
            diagnostics.record(trace)
            return .resolved(rect: rect, prepared: prepared)
        }
    }

    private func dispatchFailure(
        _ failure: AnchorlessFailure,
        _ trace: AnchorlessTrace
    ) -> AnchorlessRuntimeOutcome {
        diagnostics.record(trace)
        return .failed(failure)
    }
}
