@MainActor
public protocol DigiaCEPPlugin: AnyObject {
    var identifier: String { get }
    func setup(delegate: DigiaCEPDelegate)
    func registerPlaceholder(propertyID: String) -> Int?
    func deregisterPlaceholder(_ id: Int)
    func notifyEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload)
    func healthCheck() -> DiagnosticReport
    func teardown()
}

public extension DigiaCEPPlugin {
    func registerPlaceholder(propertyID: String) -> Int? { nil }
    func deregisterPlaceholder(_ id: Int) {}
}
