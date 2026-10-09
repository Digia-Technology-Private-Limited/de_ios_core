/// A lifecycle verb reported back for an externally-rendered guide's
/// presentation.
///
/// Guides can render outside this core — today only the React Native bridge
/// does this, via ``Digia/setOnGuideRenderRequest(_:)`` — and the renderer is
/// the only one who knows when the experience actually appeared, was tapped,
/// or closed. Something has to carry that back to the *real*
/// ``PresentationController`` the coordinator opened for the delivery, or the
/// CEP's hold never releases on its own and only the acceptance watchdog frees
/// it, 15s late and with the wrong reason.
///
/// This is that something, paired with
/// ``Digia/reportExternalGuideLifecycle(presentationId:event:)``. The pairing
/// is deliberate: the bridge gets a presentation *id* and a verb, never the
/// ``PresentationController`` itself, so there is exactly one way to drive a
/// presentation from outside this module and no way to mint or hold a second,
/// disconnected one.
///
/// Each case mirrors one write on ``PresentationController`` one-for-one, and
/// ``settled(_:)`` reuses ``PresentationOutcome`` rather than re-deriving the
/// pinned ``DismissReason`` / ``DropReason`` vocabulary a second time.
public enum ExternalGuideLifecycleEvent: Sendable, Equatable {
    /// The experience became visible. Mirrors
    /// ``PresentationController/markDisplaying()``.
    case displaying

    /// A qualifying interaction. Mirrors
    /// ``PresentationController/emitClicked(elementId:)``.
    case clicked(elementId: String?)

    /// The terminal outcome — dismissed after displaying, or dropped before it
    /// ever did. Mirrors ``PresentationController/settle(_:)``.
    case settled(PresentationOutcome)
}
