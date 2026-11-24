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

    @Test("a whitespace-only skinId skips the campaign")
    func whitespaceSkinIdSkipped() {
        // Guards the isNotBlank rule: a blank id is absent, not an id —
        // Android skips it the same way, so no skin opens with a blank id.
        var json = template()
        json["skinId"] = "   "
        #expect(GamificationConfig.fromJson(json) == nil)
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

    @Test("showClose defaults true, the top level winning over surface")
    func showCloseDefaultsTrue() {
        // Guards the showClose line in fromJson: hiding the X is opt-in,
        // like Android — a missing flag never hides it.
        #expect(GamificationConfig.fromJson(template())?.showClose == true)

        var hidden = template()
        hidden["showClose"] = false
        #expect(GamificationConfig.fromJson(hidden)?.showClose == false)

        var surfaceHidden = template()
        surfaceHidden["surface"] = ["showClose": false]
        #expect(GamificationConfig.fromJson(surfaceHidden)?.showClose == false)

        var topWins = template()
        topWins["showClose"] = true
        topWins["surface"] = ["showClose": false]
        #expect(GamificationConfig.fromJson(topWins)?.showClose == true)
    }

    @Test("the Android sensor wire names parse, unknown names skip")
    func sensorsParse() {
        // Guards the sensors loop in fromJson: every Android wire name
        // parses; an unknown name skips only itself, never the campaign.
        var json = template()
        json["sensors"] = ["gyroscope", "gravity", "light", "nope"]
        #expect(GamificationConfig.fromJson(json)?.sensors == [.gyroscope, .gravity, .light])
    }
}
