import Foundation

final class DefaultDeviceIdProvider: DeviceIdProvider, @unchecked Sendable {
    private let identityManager: IdentityManager

    init(identityManager: IdentityManager) {
        self.identityManager = identityManager
    }

    var deviceId: String {
        identityManager.getDeviceId()
    }
}
