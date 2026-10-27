import Foundation

/// Loads the shared SDK fixtures from `<workspace>/sdk_testing_fixtures/`, the catalog every Engage
/// SDK's tests read (`actions/`, `campaigns/<campaign>/`). Mirrors `loadCampaign` and
/// `_loadCampaignFixtures` in `flutter/core/test/support/sdk_harness.dart`.
///
/// The media the fixtures point at (`{{TESTKIT_ASSET_ORIGIN}}`) is still owned by the workspace
/// Test Kit; it resolves to the mock server's directory on disk, so nothing is fetched.
public enum FixtureLoader {

    /// Locates the `de_workspace` root directory by walking up from the given source file.
    public static func workspaceURL(file: StaticString = #filePath) -> URL? {
        var currentUrl = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = currentUrl.appendingPathComponent("sdk_testing_fixtures")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return currentUrl
            }
            let parent = currentUrl.deletingLastPathComponent()
            if parent.path == currentUrl.path { break }
            currentUrl = parent
        }
        return nil
    }

    /// Resolves `{{TESTKIT_ASSET_ORIGIN}}` placeholders in JSON string to local file URLs.
    public static func resolveAssetOrigin(in rawString: String, workspaceUrl: URL?) -> String {
        guard let workspaceUrl else { return rawString }
        let mockServerDir = workspaceUrl.appendingPathComponent("testkit/mock-server")
        var assetOrigin = mockServerDir.absoluteString
        if assetOrigin.hasSuffix("/") {
            assetOrigin = String(assetOrigin.dropLast())
        }
        return rawString.replacingOccurrences(of: "{{TESTKIT_ASSET_ORIGIN}}", with: assetOrigin)
    }

    /// A shared fixture by its path under `sdk_testing_fixtures/`, e.g.
    /// `actions/action_share.json` or `campaigns/nudge_dialog/nudge_dialog.json`, with its media
    /// pointed at the Test Kit's mock server. Nil when the file is missing or not a JSON object.
    public static func load(_ path: String, file: StaticString = #filePath) -> [String: Any]? {
        guard let workspaceUrl = workspaceURL(file: file),
              let data = FileManager.default.contents(
                atPath: workspaceUrl.appendingPathComponent("sdk_testing_fixtures/\(path)").path),
              let rawString = String(data: data, encoding: .utf8)
        else { return nil }
        let resolved = resolveAssetOrigin(in: rawString, workspaceUrl: workspaceUrl)
        return (try? JSONSerialization.jsonObject(with: Data(resolved.utf8))) as? [String: Any]
    }

    /// Loads `sdk_testing_fixtures/campaigns/<campaignType>/<fileName>.json`.
    ///
    /// - Parameters:
    ///   - campaignType: Subdirectory name under `campaigns/` (e.g., "nudge_dialog", "survey")
    ///   - fileName: JSON file name with or without `.json` extension (e.g., "nudge_dialog")
    ///   - fallbackJson: Optional fallback JSON string to use if the file path is unavailable
    /// - Returns: Deserialized JSON dictionary `[String: Any]`
    public static func loadFixture(
        campaignType: String,
        fileName: String,
        fallbackJson: String? = nil,
        file: StaticString = #filePath
    ) -> [String: Any]? {
        let actualFileName = fileName.hasSuffix(".json") ? fileName : "\(fileName).json"
        if let json = load("campaigns/\(campaignType)/\(actualFileName)", file: file) {
            return json
        }
        guard let fallbackJson else { return nil }
        let resolved = resolveAssetOrigin(in: fallbackJson, workspaceUrl: workspaceURL(file: file))
        return (try? JSONSerialization.jsonObject(with: Data(resolved.utf8))) as? [String: Any]
    }

    /// Names (without `.json`) of every fixture in `sdk_testing_fixtures/campaigns/<campaignType>/`,
    /// sorted, so a fixture added to the catalog is picked up without a code change. Empty when
    /// the fixtures aren't found.
    public static func fixtureNames(campaignType: String, file: StaticString = #filePath)
        -> [String]
    {
        guard let workspaceUrl = workspaceURL(file: file),
              let files = try? FileManager.default.contentsOfDirectory(
                at: workspaceUrl.appendingPathComponent("sdk_testing_fixtures/campaigns/\(campaignType)"),
                includingPropertiesForKeys: nil
              )
        else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}
