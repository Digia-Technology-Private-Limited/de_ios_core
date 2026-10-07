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

        if let campaignsUrl = campaignsDirectory(file: file) {
            let fixtureUrl = campaignsUrl
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

    /// Names (without `.json`) of every fixture in `testkit/campaigns/<campaignType>/fixtures/`,
    /// sorted, so a fixture added to the Test Kit is picked up without a code change. Empty when
    /// the Test Kit isn't found.
    public static func fixtureNames(campaignType: String, file: StaticString = #filePath) -> [String] {
        guard let campaignsUrl = campaignsDirectory(file: file),
              let files = try? FileManager.default.contentsOfDirectory(
                at: campaignsUrl.appendingPathComponent(campaignType).appendingPathComponent("fixtures"),
                includingPropertiesForKeys: nil
              )
        else { return [] }
        return files
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
