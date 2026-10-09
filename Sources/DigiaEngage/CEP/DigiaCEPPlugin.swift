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
@MainActor
public protocol DigiaCEPPlugin: AnyObject {
    /// Stable identifier, unique per registration. Convention: the lowercase
    /// CEP name — `clevertap`, `webengage`, `moengage`.
    var id: String { get }

    /// Called once by `Digia.register()`. Store the `host` and start listening
    /// to the CEP SDK.
    ///
    /// Core never holds a trigger. While ``DigiaCEPHost/isReady`` is false the
    /// plugin holds its own payloads in a ``PendingPayloadBuffer`` and flushes
    /// them in ``onHostReady()``. A delivery made before the SDK is ready
    /// settles at once as dropped (`not_initialized`, `not_ready` or
    /// `initialization_failed`).
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

    /// Called on the attached plugin when Core becomes READY. Flush buffered
    /// payloads here. Optional — the default is a no-op.
    func onHostReady()

    /// Called on the attached plugin when initialization fails, and right after
    /// ``attach(host:)`` if it has already failed. Drop buffered payloads with
    /// `initialization_failed` and stop buffering. Optional — the default is a no-op.
    func onHostInitFailed()
}

/// The optional half of the protocol.
///
/// The defaults live here so a plugin only writes the methods its CEP has, and
/// so a later optional method is an additive change rather than a break —
/// which matters for an SDK that ships inside someone else's app.
extension DigiaCEPPlugin {
    public func onScreenChanged(_ screenName: String) {}
    public func trackEvent(_ eventName: String, properties: [String: Any]) {}
    public func onHostReady() {}
    public func onHostInitFailed() {}
}
