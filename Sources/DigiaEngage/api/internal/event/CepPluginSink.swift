import Foundation

/// Delivers coarse ``DigiaExperienceEvent``s to the registered CEP plugin.
///
/// The CEP channel is a campaign-agnostic protocol — the plugin only understands
/// Impressed/Clicked/Dismissed. Ported from Android
/// `internal/event/CepPluginSink.kt`; the supplied closure is a clean no-op when
/// no plugin is registered, so callers fire unconditionally.
@MainActor
final class CepPluginSink {
    private let notify: (DigiaExperienceEvent, CEPTriggerPayload) -> Void

    init(notify: @escaping (DigiaExperienceEvent, CEPTriggerPayload) -> Void) {
        self.notify = notify
    }

    func deliver(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        notify(event, payload)
    }
}
