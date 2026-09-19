/// Implemented by each CEP plugin package — `DigiaEngageCleverTap`,
/// `DigiaEngageWebEngage`, `DigiaEngageMoEngage`.
///
/// Core calls into this; plugin authors implement it. Core never imports a CEP
/// SDK, and a plugin never holds core internals — only its ``DigiaCEPHost``.
///
/// The whole job reduces to three moves: **deliver, subscribe,
/// release-on-outcome.**
///
/// ```swift
/// let presentation = host.deliver(trigger)
/// _ = presentation.onSignal(forwardMarkingToTheCep)
/// Task { @MainActor in
///     await presentation.holdReleased.value
///     releaseTheCepSlot()
/// }
/// ```
///
/// **The `V2` suffix is temporary and must never appear in a published
/// release.** v1's `DigiaCEPPlugin` still occupies the name inside this module
/// and dies at N4; this protocol is renamed to `DigiaCEPPlugin` in the same
/// change, in-tree, before anything ships. It is the only name in the v2
/// surface that carries a suffix — everything else already mirrors Kotlin and
/// Dart exactly.
@MainActor
public protocol DigiaCEPPluginV2: AnyObject {
    /// Stable identifier, unique per registration. Convention: the lowercase
    /// CEP name — `clevertap`, `webengage`, `moengage`.
    var id: String { get }

    /// Called once by `Digia.register()`. Store the `host` and start listening
    /// to the CEP SDK.
    ///
    /// CEP events that arrive before this runs are the plugin's own problem to
    /// buffer — including the case where `Digia.initialize()` is never called
    /// at all, which is the one timer a plugin still owns.
    func attach(host: DigiaCEPHost)

    /// Called by `Digia.unregister()`, or when a replacement plugin is
    /// registered — **after** core has settled every presentation this plugin
    /// owns with `DropReason.pluginDetached` / `DismissReason.pluginDetached`.
    ///
    /// Those outcome awaiters may still be running when this is called, so
    /// release logic must not depend on being attached.
    func detach()

    /// Forwards a screen change to the CEP's own screen tracking. Optional —
    /// the default is a no-op.
    func onScreenChanged(_ screenName: String)

    /// Receives Digia's rich first-party analytics events, for campaigns this
    /// plugin owns only. Optional — the default is a no-op.
    func trackEvent(_ eventName: String, properties: [String: Any])
}

/// The optional half of the protocol.
///
/// The defaults live here so a plugin only writes the methods its CEP has, and
/// so a later optional method is an additive change rather than a break —
/// which matters for an SDK that ships inside someone else's app.
extension DigiaCEPPluginV2 {
    public func onScreenChanged(_ screenName: String) {}
    public func trackEvent(_ eventName: String, properties: [String: Any]) {}
}
