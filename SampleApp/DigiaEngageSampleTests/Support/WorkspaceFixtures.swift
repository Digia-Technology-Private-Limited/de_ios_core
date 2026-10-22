import Foundation
import Testing

/// The shared SDK fixtures live in the workspace's `sdk_testing_fixtures` (read, never copied), and the
/// Test Kit still owns the media they point at. This repo is cloned at `<workspace>/ios/core`.
enum WorkspaceFixtures {
    /// `<workspace>`, found from this file's location: `ios/core/SampleApp/DigiaEngageSampleTests/Support/`.
    static let workspace: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        return url
    }()

    static let fixtures = workspace.appendingPathComponent("sdk_testing_fixtures")
    static let testkitAssets = workspace.appendingPathComponent("testkit/mock-server/assets")

    /// Stand-in origin for `{{TESTKIT_ASSET_ORIGIN}}`; `StubBackend` serves it from `testkitAssets`.
    static let assetOrigin = "https://testkit.local"

    /// Why a media-driven test cannot run, or nil when the Test Kit is cloned beside this repo.
    static var skipReason: String? {
        FileManager.default.fileExists(atPath: testkitAssets.path)
            ? nil
            : "Test Kit not found at \(testkitAssets.path); run `bash clone.sh` in de_workspace"
    }

    /// One campaign fixture: its file name (without `.json`) and the campaign object the bundle carries.
    struct Campaign: CustomTestStringConvertible, Sendable {
        let name: String
        let json: [String: any Sendable]

        var testDescription: String { name }
        var campaignKey: String { json["campaignKey"] as? String ?? "" }

        /// The inline slot the campaign is authored for: the first `slotKey` in the template.
        var slotKey: String? { Self.firstValue(of: "slotKey", in: json["templateConfig"]) as? String }

        /// The screens the campaign is scoped to, if any.
        var targetScreens: [String] { ((json["targetScreenNames"] as? [String: Any])?["names"] as? [String]) ?? [] }

        /// The same campaign with its wall-clock timers held off for a day: an auto-dismiss at its authored
        /// length would end the showing at a different point of every run, and a story page's progress bar
        /// would stand at a different spot. The decision they drive is checked by the behaviour tests.
        func holdingTimers() -> Campaign {
            func hold(_ value: Any) -> any Sendable {
                switch value {
                case let dict as [String: Any]:
                    return dict.reduce(into: [String: any Sendable]()) { out, pair in
                        switch pair.key {
                        case "autoDismissAfterMs": out[pair.key] = NSNumber(value: 86_400_000)
                        case "durationSeconds" where pair.value is NSNumber: out[pair.key] = NSNumber(value: 86_400)
                        default: out[pair.key] = hold(pair.value)
                        }
                    }
                case let array as [Any]: return array.map(hold)
                default: return SendableBox.wrap(value)
                }
            }
            return Campaign(name: name, json: json.mapValues { hold($0) })
        }

        /// The value each runtime variable falls back to when the CEP sends none, by name.
        var fallbackVariables: [String: String] {
            var found: [String: String] = [:]
            func walk(_ value: Any?) {
                switch value {
                case let dict as [String: Any]:
                    if let list = dict["variables"] as? [[String: Any]] {
                        for item in list { if let name = item["name"] as? String, let value = item["fallbackValue"] as? String { found[name] = value } }
                    }
                    dict.values.forEach(walk)
                case let array as [Any]: array.forEach(walk)
                default: break
                }
            }
            walk(json["templateConfig"])
            return found
        }

        private static func firstValue(of key: String, in value: Any?) -> Any? {
            switch value {
            case let dict as [String: Any]:
                if let found = dict[key] { return found }
                return dict.values.lazy.compactMap { firstValue(of: key, in: $0) }.first
            case let array as [Any]:
                return array.lazy.compactMap { firstValue(of: key, in: $0) }.first
            default:
                return nil
            }
        }
    }

    /// A fixture by path under `sdk_testing_fixtures/`, e.g. `actions/action_copy_to_clipboard.json`.
    static func campaign(_ path: String) -> Campaign {
        let url = fixtures.appendingPathComponent(path)
        return decode(url, name: url.deletingPathExtension().lastPathComponent)
    }

    /// Every fixture in `sdk_testing_fixtures/campaigns/<directory>`, sorted by name, so a fixture added to
    /// the workspace is picked up without a code change.
    static func campaigns(in directory: String) -> [Campaign] {
        let dir = fixtures.appendingPathComponent("campaigns/\(directory)")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { decode($0, name: $0.deletingPathExtension().lastPathComponent) }
    }

    private static func decode(_ url: URL, name: String) -> Campaign {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let object = try? JSONSerialization.jsonObject(
                with: Data(text.replacingOccurrences(of: "{{TESTKIT_ASSET_ORIGIN}}", with: assetOrigin).utf8)
              ),
              let json = object as? [String: Any]
        else { fatalError("Unreadable fixture \(url.path)") }
        return Campaign(name: name, json: json.mapValues { SendableBox.wrap($0) })
    }
}

/// JSON values are plain Foundation types; boxing them as `Sendable` lets a fixture cross into a
/// parameterized test's arguments under Swift 6.
enum SendableBox {
    static func wrap(_ value: Any) -> any Sendable {
        switch value {
        case let dict as [String: Any]: return dict.mapValues { wrap($0) }
        case let array as [Any]: return array.map { wrap($0) }
        case let string as String: return string
        case let number as NSNumber: return number
        default: return NSNull()
        }
    }
}
