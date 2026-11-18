import Foundation
import Testing

@testable import DigiaEngage

/// Guards the skin `minSdkVersion` handling: the production lines are the
/// `isNewer` comparison, the parse-time keep (routing and the rewards surface
/// own the gate), and the lenient unreadable-requirement arm.
@Suite("Gamification config", .tags(.unit, .game))
struct GamificationConfigTests {
    private func template(minSdkVersionIos: String? = nil) -> [String: Any] {
        var config: [String: Any] = [:]
        if let minSdkVersionIos {
            config["minSdkVersion"] = ["ios": minSdkVersionIos]
        }
        return [
            "skinId": "wheel",
            "skinVersion": 2,
            "bundleUrl": "https://cdn.example.com/skins/wheel/2/index.html",
            "templateType": "spinWheel",
            "config": config,
        ]
    }

    @Test("an unreadable requirement never skips a campaign")
    func unreadableRequirementIsLenient() {
        // Guards the nil arm of isNewer: garbage degrades to no gate.
        #expect(GamificationConfig.fromJson(template(minSdkVersionIos: "soon")) != nil)
    }

    @Test("semver compares numerically, tolerating short forms")
    func semver() {
        #expect(GamificationConfig.isNewer("4.4", than: "4.3.2") == true)
        #expect(GamificationConfig.isNewer("4.3.2", than: "4.3.2") == false)
        #expect(GamificationConfig.isNewer("4.3", than: "4.3.2") == false)
        #expect(GamificationConfig.isNewer("4.10.0", than: "4.9.9") == true)
        #expect(GamificationConfig.isNewer("abc", than: "4.3.2") == nil)
        #expect(GamificationConfig.isNewer("4.3.2", than: "abc") == nil)
        #expect(GamificationConfig.isNewer("4.3.2.1", than: "4.3.2") == nil)
    }

    @Test("the bridge gate passes absent or current versions and blocks newer")
    func bridgeGate() {
        // Guards `bridgeSupported` (VER-3): absent means current; newer never opens.
        func config(_ version: Int?) -> GamificationConfig? {
            var json = template()
            if let version { json["bridgeVersion"] = version }
            return GamificationConfig.fromJson(json)
        }
        #expect(config(nil)?.bridgeSupported == true)
        #expect(config(GameBridge.bridgeVersion)?.bridgeSupported == true)
        #expect(config(GameBridge.bridgeVersion + 1)?.bridgeSupported == false)
    }
}
