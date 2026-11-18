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

    @Test("a skin needing a newer SDK parses, keeping its requirement")
    func newerSdkParses() {
        // Guards the label rule: the game type and SDK requirement never drop
        // the campaign at parse time — routing refuses it as unsupported_sdk,
        // and the rewards surface rechecks at open.
        let parsed = GamificationConfig.fromJson(template(minSdkVersionIos: "99.0"))
        #expect(parsed?.minSdkVersion == "99.0")
    }

    @Test("a skin within this SDK parses, keeping its requirement")
    func currentSdkParses() {
        let parsed = GamificationConfig.fromJson(template(minSdkVersionIos: "1.0"))
        #expect(parsed?.minSdkVersion == "1.0")
        #expect(parsed?.skinId == "wheel")
        #expect(parsed?.skinVersion == 2)
        #expect(GamificationConfig.fromJson(template())?.minSdkVersion == nil)
    }

    @Test("an unreadable requirement never skips a campaign")
    func unreadableRequirementIsLenient() {
        // Guards the nil arm of isNewer: garbage degrades to no gate.
        #expect(GamificationConfig.fromJson(template(minSdkVersionIos: "soon")) != nil)
    }

    @Test("an unknown sensor name skips only that sensor")
    func unknownSensorSkipped() {
        var json = template()
        json["sensors"] = ["haptics", "lidar", "gyroscope"]

        // Guards the skip in fromJson: a new sensor name must not drop the
        // whole campaign on older SDKs.
        let parsed = GamificationConfig.fromJson(json)
        #expect(parsed?.sensors == [.haptics, .gyroscope])
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
}
