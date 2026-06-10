import Combine

@MainActor
final class AppConfigStore: ObservableObject {
    @Published private(set) var appConfig: DigiaAppConfig?
    @Published private(set) var lastError: String?
    @Published private(set) var isLoading = false

    func update(_ appConfig: DigiaAppConfig) {
        self.appConfig = appConfig
        self.lastError = nil
        self.isLoading = false
    }

    func setLoading() {
        isLoading = true
        lastError = nil
    }

    func setError(_ message: String) {
        lastError = message
        isLoading = false
    }

    func clear() {
        appConfig = nil
        lastError = nil
        isLoading = false
    }

    func isPage(_ id: String) -> Bool {
        page(id) != nil
    }

    func page(_ id: String) -> PageDefinition? {
        appConfig?.page(id)
    }

    func component(_ id: String) -> ComponentDefinition? {
        appConfig?.component(id)
    }

    func themeColor(named token: String) -> String? {
        appConfig?.theme.colors?.light[token]
    }

}
