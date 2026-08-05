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

    @Test("matches and extracts an authenticated capture pairing query")
    func matchesPairingQuery() {
        let url = URL(
            string: "medihubrn://_digia/debug-settings?pairingToken=short-lived-proof"
        )!
        #expect(Digia.isDebugSettingsDeepLink(url))
        #expect(Digia.debugSettingsPairingToken(from: url) == "short-lived-proof")
    }

    @Test("rejects an unrelated deeplink")
    func rejectsUnrelated() {
        #expect(!Digia.isDebugSettingsDeepLink(URL(string: "myapp://home")!))
    }

    @Test("rejects a path that only shares a prefix")
    func rejectsSharedPrefix() {
        #expect(!Digia.isDebugSettingsDeepLink(URL(string: "myapp://_digia/debug-settings-extra")!))
    }

    @Test("parses an exact Test Kit native-export request")
    func parsesTestKitExportRequest() throws {
        let request = try #require(Digia.testKitExportRequest(from: URL(
            string: "medihubrn://_digia/testkit/export?runId=run-ios-001&token=local-token"
        )!))
        #expect(request.runId == "run-ios-001")
        #expect(request.token == "local-token")
    }

    @Test("rejects incomplete or lookalike Test Kit export links")
    func rejectsInvalidTestKitExportRequest() {
        #expect(Digia.testKitExportRequest(from: URL(
            string: "medihubrn://_digia/testkit/export?runId=run-ios-001"
        )!) == nil)
        #expect(Digia.testKitExportRequest(from: URL(
            string: "medihubrn://_digia/testkit/export-extra?runId=run-ios-001&token=x"
        )!) == nil)
    }
}
