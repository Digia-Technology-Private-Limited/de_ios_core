import Foundation

/// Central test utility to load wire fixtures from the shared `testkit/campaigns/` catalog.
public enum FixtureLoader {

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

        // Walk up from current file to find de_workspace root
        var currentUrl = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        var workspaceUrl: URL? = nil

        for _ in 0..<10 {
            let candidate = currentUrl.appendingPathComponent("testkit/campaigns")
            if FileManager.default.fileExists(atPath: candidate.path) {
                workspaceUrl = currentUrl
                break
            }
            let parent = currentUrl.deletingLastPathComponent()
            if parent.path == currentUrl.path { break }
            currentUrl = parent
        }

        if let workspaceUrl = workspaceUrl {
            let fixtureUrl = workspaceUrl
                .appendingPathComponent("testkit/campaigns")
                .appendingPathComponent(campaignType)
                .appendingPathComponent("fixtures")
                .appendingPathComponent(actualFileName)

            if FileManager.default.fileExists(atPath: fixtureUrl.path),
               let data = FileManager.default.contents(atPath: fixtureUrl.path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return json
            }
        }

        // Use fallback if provided
        if let fallbackJson = fallbackJson,
           let data = fallbackJson.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        return nil
    }
}
