import Foundation
import Testing
@testable import DigiaEngage

@MainActor
@Suite("Digia.isDebugSettingsDeepLink")
struct DigiaDebugSettingsDeepLinkTests {

    @Test("matches a custom-scheme deeplink")
    func matchesCustomScheme() {
        #expect(Digia.isDebugSettingsDeepLink(URL(string: "myapp://_digia/debug-settings")!))
    }

    @Test("matches a universal (https) link with the path as a suffix")
    func matchesUniversalLink() {
        #expect(Digia.isDebugSettingsDeepLink(URL(string: "https://example.com/_digia/debug-settings")!))
    }

    @Test("tolerates a trailing slash")
    func toleratesTrailingSlash() {
        #expect(Digia.isDebugSettingsDeepLink(URL(string: "myapp://_digia/debug-settings/")!))
    }

    @Test("rejects an unrelated deeplink")
    func rejectsUnrelated() {
        #expect(!Digia.isDebugSettingsDeepLink(URL(string: "myapp://home")!))
    }

    @Test("rejects a path that only shares a prefix")
    func rejectsSharedPrefix() {
        #expect(!Digia.isDebugSettingsDeepLink(URL(string: "myapp://_digia/debug-settings-extra")!))
    }
}
