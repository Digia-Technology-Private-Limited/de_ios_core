/// Core's door, handed to each plugin in ``DigiaCEPPluginV2/attach(host:)``.
/// The plugin's only way into the Digia engine.
///
/// Each plugin receives its own host instance, so the presentations it creates
/// are stamped with its ownership and its signals never reach another plugin.
@MainActor
public protocol DigiaCEPHost: AnyObject {
    /// Delivers a CEP trigger into the Digia engine.
    ///
    /// A total function: it never fails, and always returns a handle. A
    /// synchronous rejection — unknown key, invalid config, missing anchor —
    /// returns an *already settled* presentation, so the caller has one code
    /// path either way.
    ///
    /// Returns **synchronously**, and must keep doing so: the handle is a
    /// receipt, not an answer. The answer arrives later on
    /// ``CampaignPresentation/outcome``. A plugin needs its synchronous grip
    /// on the handle because a CEP can close a template milliseconds after
    /// presenting it — without it, `cancel()` would be racy and the plugin
    /// would need a side-map to correlate CEP context with a handle that
    /// arrives later. Never make this `async`.
    func deliver(_ trigger: CEPTriggerPayload) -> CampaignPresentation
}
