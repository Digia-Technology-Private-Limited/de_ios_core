import Foundation

/// Central test utility to load wire fixtures from the shared `testkit/campaigns/` catalog.
public enum FixtureLoader {

    /// Locates the `de_workspace` root directory by walking up from the given source file.
    public static func workspaceURL(file: StaticString = #filePath) -> URL? {
        var currentUrl = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = currentUrl.appendingPathComponent("testkit/campaigns")
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

    /// Loads a campaign JSON fixture from `testkit/campaigns/<campaignType>/fixtures/<fileName>.json`.
    ///
    /// - Parameters:
    ///   - campaignType: Subdirectory name under `testkit/campaigns/` (e.g., "nudge_dialog", "survey")
    ///   - fileName: JSON file name with or without `.json` extension (e.g., "nudge-dialog.json")
    ///   - fallbackJson: Optional fallback JSON string to use if the file path is unavailable
    /// - Returns: Deserialized JSON dictionary `[String: Any]`
    public static func loadFixture(
        campaignType: String,
        fileName: String,
        fallbackJson: String? = nil,
        file: StaticString = #filePath
    ) -> [String: Any]? {
        let actualFileName = fileName.hasSuffix(".json") ? fileName : "\(fileName).json"
        let workspaceUrl = workspaceURL(file: file)

        if let workspaceUrl = workspaceUrl {
            let fixtureUrl =
                workspaceUrl
                .appendingPathComponent("testkit/campaigns")
                .appendingPathComponent(campaignType)
                .appendingPathComponent("fixtures")
                .appendingPathComponent(actualFileName)

            if FileManager.default.fileExists(atPath: fixtureUrl.path),
                let data = FileManager.default.contents(atPath: fixtureUrl.path),
                let rawString = String(data: data, encoding: .utf8)
            {
                let resolved = resolveAssetOrigin(in: rawString, workspaceUrl: workspaceUrl)
                if let resolvedData = resolved.data(using: .utf8),
                    let json = try? JSONSerialization.jsonObject(with: resolvedData)
                        as? [String: Any]
                {
                    return json
                }
            }
        }

        // Use fallback if provided
        if let fallbackJson = fallbackJson {
            let resolved = resolveAssetOrigin(in: fallbackJson, workspaceUrl: workspaceUrl)
            if let resolvedData = resolved.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: resolvedData) as? [String: Any]
            {
                return json
            }
        }

        return nil
    }

    /// Names (without `.json`) of every fixture in `testkit/campaigns/<campaignType>/fixtures/`,
    /// sorted, so a fixture added to the Test Kit is picked up without a code change. Empty when
    /// the Test Kit isn't found.
    public static func fixtureNames(campaignType: String, file: StaticString = #filePath)
        -> [String]
    {
        guard let campaignsUrl = campaignsDirectory(file: file),
            let files = try? FileManager.default.contentsOfDirectory(
                at: campaignsUrl.appendingPathComponent(campaignType).appendingPathComponent(
                    "fixtures"),
                includingPropertiesForKeys: nil
            )
        else { return [] }
        return
            files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// Walks up from the calling source file to the de_workspace root's `testkit/campaigns`.
    private static func campaignsDirectory(file: StaticString) -> URL? {
        var currentUrl = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = currentUrl.appendingPathComponent("testkit/campaigns")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = currentUrl.deletingLastPathComponent()
            if parent.path == currentUrl.path { break }
            currentUrl = parent
        }
        return nil
    }
}
