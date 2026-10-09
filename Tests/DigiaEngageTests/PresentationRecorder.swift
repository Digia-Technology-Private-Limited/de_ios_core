import Foundation
@testable import DigiaEngage

/// What the owning CEP plugin would have seen for one delivered campaign.
///
/// v1's tests registered a plugin and read the `notifyEvent` calls core pushed
/// at it. Under v2 there is no push: core settles a handle and the owner reads
/// it. So this wraps the read face and records what arrives on it — signals as
/// they are delivered, the outcome as it settles.
///
/// Everything here is synchronous. ``PresentationPromise`` stores its value at
/// `settle()`, so `settledValue` is readable on the very next line — the async
/// `value` accessor exists for a plugin that wants to *wait*, not for a test
/// that already knows the settle has happened.
///
/// platform note: the Dart twin is `test/support/presentation_recorder.dart`.
/// Its outcome arrives on a microtask; Swift's is readable immediately.
@MainActor
final class PresentationRecorder {
    /// Records an already-delivered presentation — the `SDKInstance.deliver`
    /// path, where routing chose the kind.
    init(_ presentation: CampaignPresentation) {
        self.presentation = presentation
        payload = presentation.trigger
        unsubscribe = presentation.onSignal { [weak self] signal in
            self?.signals.append(signal)
        }
    }

    /// Opens a presentation directly on the SDK's coordinator, for a surface a
    /// test drives by hand rather than through `deliver()`.
    ///
    /// `kind` matters: it decides whether the acceptance watchdog is armed and
    /// whether the CEP's hold ends at the impression, so a test that gets it
    /// wrong is testing a different campaign type than it thinks. The default is
    /// `inline` — no watchdog, nothing to leak into the next test.
    convenience init(
        payload: CEPTriggerPayload,
        kind: PresentationKind = .inline,
        owner: String = "test"
    ) {
        let coordinator = SDKInstance.shared.coordinator
        let controller = coordinator.open(payload, owner: owner)
        coordinator.accept(controller, kind: kind)
        self.init(controller.presentation)
    }

    deinit { MainActor.assumeIsolated { unsubscribe?() } }

    /// The read face, as the plugin would hold it.
    let presentation: CampaignPresentation

    /// The *stamped* payload — the instance every render surface must be handed,
    /// and the only one a lifecycle event can be traced back from.
    let payload: CEPTriggerPayload

    /// Every signal delivered, in order.
    private(set) var signals: [PresentationSignal] = []

    private var unsubscribe: (@MainActor () -> Void)?

    /// The terminal outcome, or nil while it is still running.
    var outcome: PresentationOutcome? { presentation.outcome.settledValue }

    /// Whether the outcome has been decided.
    var isSettled: Bool { presentation.outcome.isSettled }

    /// Whether the CEP has been told it may release its hold.
    var isHoldReleased: Bool { presentation.holdReleased.isSettled }

    /// Whether the experience reported itself visible.
    var displayed: Bool { signals.contains(.displayed) }

    /// Every qualifying interaction's element id, in order.
    var clickedElementIds: [String?] {
        signals.compactMap { signal in
            if case .clicked(let elementId) = signal { return elementId }
            return nil
        }
    }

    /// The drop reason, when it was dropped.
    var dropReason: DropReason? {
        if case .dropped(let reason, _) = outcome { return reason }
        return nil
    }

    /// The dismiss reason, when it displayed and then ended.
    var dismissReason: DismissReason? {
        if case .dismissed(let reason, _) = outcome { return reason }
        return nil
    }
}
