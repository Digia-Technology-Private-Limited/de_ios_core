@MainActor
public protocol DigiaCEPPlugin: AnyObject {
    func setup(delegate: DigiaCEPDelegate)
    func registerPlaceholder(propertyID: String) -> Int?
    func deregisterPlaceholder(_ id: Int)
    func notifyEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload)
    /// Forward an overlay CTA action (deep link / URL) to the CEP. Returns `true`
    /// if the plugin handled it, so the renderer skips its native fallback (open
    /// URL). Mirrors Android's `notifyAction(...) -> Boolean`.
    func notifyAction(actionType: String, url: String, payload: CEPTriggerPayload) -> Bool
    func healthCheck() -> DiagnosticReport
    func teardown()
}

extension DigiaCEPPlugin {
    public func registerPlaceholder(propertyID: String) -> Int? { nil }
    public func deregisterPlaceholder(_ id: Int) {}
    public func notifyAction(actionType: String, url: String, payload: CEPTriggerPayload) -> Bool { false }
}
