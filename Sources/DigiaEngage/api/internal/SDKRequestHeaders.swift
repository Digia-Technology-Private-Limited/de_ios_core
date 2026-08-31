import Foundation

enum SDKRequestHeaders {
    static func make(config: DigiaConfig, deviceId: String) -> [String: String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var system = utsname()
        uname(&system)
        let model = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        var headers = [
            "x-digia-project-id": config.apiKey,
            "x-digia-device-id": deviceId,
            "x-digia-platform": "ios",
            "x-digia-sdk-version": buildSdkVersion(
                binding: config.wrapperBinding ?? "native",
                platform: "ios",
                wrapperVersion: config.wrapperVersion,
                core: DigiaSdkVersion.value
            ),
            "x-digia-sdk-environment": config.environment == .sandbox ? "sandbox" : "production",
            "x-digia-device-make": "Apple",
            "x-digia-os-version": "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        ]
        let optional: [String: String?] = [
            "x-digia-device-model": model,
            "x-app-package-name": Bundle.main.bundleIdentifier,
            "x-app-version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            "x-app-build-number": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
        ]
        for (key, value) in optional {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                headers[key] = value
            }
        }
        return headers
    }
}
