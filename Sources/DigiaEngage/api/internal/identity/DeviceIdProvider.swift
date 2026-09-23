import Foundation

protocol DeviceIdProvider: AnyObject, Sendable {
    var deviceId: String { get }
    func getDeviceId() -> String
}

extension DeviceIdProvider {
    func getDeviceId() -> String {
        deviceId
    }
}
