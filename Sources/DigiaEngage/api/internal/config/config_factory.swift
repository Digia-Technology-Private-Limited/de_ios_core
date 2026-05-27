import Foundation

enum DigiaConfigStrategyFactory {
    static func createStrategy(for config: DigiaConfig) throws -> DigiaConfigSource {
        return NetworkConfigSource(
            baseURL: resolveConfigBaseURL(config: config),
            path: "/config/getAppConfig",
            headers: makeDigiaHeaders(config: config),
            body: [:]
        )
    }
}

private func resolveConfigBaseURL(config: DigiaConfig) -> String {
    if let override = config.baseUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
        let trimmed = override.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.hasSuffix("/api/v1") ? trimmed : trimmed + "/api/v1"
    }
    return config.developerConfig?.baseURL ?? "https://app.digia.tech/api/v1"
}

private func makeDigiaHeaders(config: DigiaConfig) -> [String: String] {
    let bundle = Bundle.main
    let packageName = bundle.bundleIdentifier ?? "com.digia.sample"
    let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    let environment = config.environment == .production ? "production" : "sandbox"

    return [
        "x-digia-version": "ios-dev",
        "x-digia-project-id": config.apiKey,
        "x-digia-platform": "ios",
        "x-app-package-name": packageName,
        "x-app-version": appVersion,
        "x-app-build-number": buildNumber,
        "x-digia-environment": environment,
    ]
}

