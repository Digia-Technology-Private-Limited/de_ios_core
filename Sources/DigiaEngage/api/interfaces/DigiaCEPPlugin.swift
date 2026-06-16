@MainActor
public protocol DigiaCEPPlugin: AnyObject {
    func setup(delegate: DigiaCEPDelegate)
    func registerPlaceholder(propertyID: String) -> Int?
    func deregisterPlaceholder(_ id: Int)
    func notifyEvent(_ event: DigiaExperienceEvent, payload: InAppPayload)
    func notifyAction(actionType: String, url: String, payload: InAppPayload)
    func healthCheck() -> DiagnosticReport
    func teardown()
}

public extension DigiaCEPPlugin {
    func registerPlaceholder(propertyID: String) -> Int? { nil }
    func deregisterPlaceholder(_ id: Int) {}
    func notifyAction(actionType: String, url: String, payload: InAppPayload) {}
}
