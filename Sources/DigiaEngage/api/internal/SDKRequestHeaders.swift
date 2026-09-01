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
            "X-Digia-Project-Id": config.apiKey,
            "X-Digia-Device-Id": deviceId,
            "X-Digia-Platform": "ios",
            "x-digia-sdk-version": buildSdkVersion(
                binding: config.wrapperBinding ?? "native",
                platform: "ios",
                wrapperVersion: config.wrapperVersion,
                core: DigiaSdkVersion.value
            ),
            "x-digia-sdk-environment": config.environment == .sandbox ? "sandbox" : "production",
            "X-Digia-Device-Make": "Apple",
            "x-digia-os-version": "iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        ]
        let optional: [String: String?] = [
            "X-Digia-Device-Model": model,
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
