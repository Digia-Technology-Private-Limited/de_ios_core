import Foundation

/// Turns a rendered experience's lifecycle events into presentation state.
///
/// This was `CepPluginSink`, which called `plugin.notifyEvent(...)` — core
/// pushing at whichever plugin happened to be registered, with no idea which
/// campaign the plugin thought it was hearing about. Under v2 there is no push:
/// the owning plugin is already listening on its own handle, so all this does is
/// hand the event to the coordinator, which routes it to that one handle and to
/// no other.
///
/// The indirection stays because it is the seam the emitter is built around —
/// ``EngageEventEmitter`` holds a presentation sink and a Digia analytics sink
/// and knows nothing about either's insides. Ported from Android
/// `internal/event/PresentationSink.kt`.
@MainActor
final class PresentationSink {
    private let coordinator: () -> PresentationCoordinator?

    init(coordinator: @escaping () -> PresentationCoordinator?) {
        self.coordinator = coordinator
    }

    /// Applies `event` to the presentation that owns `payload`, if it is still
    /// live. A payload with no live presentation is a clean no-op.
    func deliver(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        coordinator()?.handle(event, payload: payload)
    }
}
