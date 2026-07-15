@MainActor
public protocol DigiaCEPPlugin: AnyObject {
    /// A stable, human-readable name for this plugin (e.g. "CleverTap")
    var identifier: String { get }

    func setup(delegate: DigiaCEPDelegate)

    /// Forwards the current screen name (set via `Digia.setCurrentScreen`) to the plugin, e.g.
    /// so it can annotate campaign events with the screen they occurred on.
    func forwardScreen(_ name: String)

    /// iOS-only extension (not present in the Flutter/RN/Android core contract): lets a plugin
    /// reserve a native placeholder view for a property before it renders. Returns an opaque
    /// handle to pass to `deregisterPlaceholder`, or `nil` if the plugin doesn't support
    /// placeholders. Defaults to `nil` (no-op).
    func registerPlaceholder(propertyID: String) -> Int?

    /// Releases a placeholder previously reserved by `registerPlaceholder`. Defaults to a no-op.
    func deregisterPlaceholder(_ id: Int)
    func notifyEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload)
    func notifyAction(actionType: String, url: String, payload: CEPTriggerPayload) -> Bool
    func healthCheck() -> DiagnosticReport
    func teardown()
}

extension DigiaCEPPlugin {
    public func registerPlaceholder(propertyID: String) -> Int? { nil }
    public func deregisterPlaceholder(_ id: Int) {}
    public func notifyAction(actionType: String, url: String, payload: CEPTriggerPayload) -> Bool { false }
}
