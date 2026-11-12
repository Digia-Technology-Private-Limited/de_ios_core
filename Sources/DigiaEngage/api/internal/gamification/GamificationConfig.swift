import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

struct GamificationSlotConfig: Equatable, Sendable {
    let outcomeKey: String
    let values: [String: String]
}

/// A parsed gamification campaign: the skin reference, its config, and the
/// surface it opens on. Parsed in `CampaignModel.fromJson` ("gamification").
/// A nil return skips the campaign; `CampaignBundle` already logs every skip
/// with the campaign key, so no log here.
struct GamificationConfig: Equatable, Sendable {
    let skinId: String
    let skinVersion: Int
    /// The skin's declared `bridgeVersion`. Compared against the SDK's in T10;
    /// carried, never gated, here.
    let bridgeVersion: Int?
    let format: GamificationFormat
    /// `config.values`, carried opaquely until the T8 `init` sends them.
    let values: [String: JSONValue]
    /// `config.slots`, kept only for formats that map outcomes to slots.
    let slots: [GamificationSlotConfig]
    let entryKind: GamificationEntryKind
    let surfaceStyle: GamificationSurfaceStyle
    let showMute: Bool
    let bundleUrl: String
    let sensors: [GamificationSkinSensor]
    /// Inline slot for the ERD 1b teaser entry. Parsed, not routed, until then.
    /// `teaser` is ignored entirely until ERD 1b.
    let slotKey: String?

    /// Only `spinWheel` and `slotMachine` map slots; the ERD leaves `slots`
    /// out of `init` for `scratchCard` and `rewardChest`.
    var usesSlots: Bool {
        format == .spinWheel || format == .slotMachine
    }

    /// `templateConfig` is the campaign's own; `campaignLevel` is the campaign
    /// object, read only for `bundleUrl`/`sensors` as a fallback — the backend
    /// adds them next to `templateConfig`, and either placement is accepted.
    static func fromJson(
        _ templateConfig: [String: Any], campaignLevel: [String: Any]? = nil
    ) -> GamificationConfig? {
        guard let skinId = templateConfig.nonBlankString("skinId"),
              let skinVersion = positiveInt(templateConfig["skinVersion"])
        else { return nil }
        let bundleUrl =
            templateConfig.nonBlankString("bundleUrl")
            ?? campaignLevel?.nonBlankString("bundleUrl")
        guard let bundleUrl, URL(string: bundleUrl) != nil else { return nil }

        let format = GamificationFormat(wire: templateConfig.string("templateType"))
        guard format != .unknown else { return nil }

        let entryKind = GamificationEntryKind(wire: templateConfig.object("entry")?.string("kind"))
        guard entryKind == .direct else { return nil }

        let surface = templateConfig.object("surface")
        let surfaceStyle = GamificationSurfaceStyle(wire: surface?.string("style"))
        guard surfaceStyle != .unknown else { return nil }

        let rawSensors =
            (templateConfig["sensors"] as? [Any])
            ?? (campaignLevel?["sensors"] as? [Any]) ?? []
        var sensors: [GamificationSkinSensor] = []
        sensors.reserveCapacity(rawSensors.count)
        for raw in rawSensors {
            let sensor = GamificationSkinSensor(wire: raw as? String)
            guard sensor != .unknown else { return nil }
            sensors.append(sensor)
        }

        let config = templateConfig.object("config") ?? [:]
        var values: [String: JSONValue] = [:]
        for (key, raw) in (config["values"] as? [String: Any]) ?? [:] {
            guard let mapped = GamificationJSON.value(raw) else {
                log.d("Gamification config value dropped — not JSON (key=\(key))")
                continue
            }
            values[key] = mapped
        }

        var slots: [GamificationSlotConfig] = []
        if format == .spinWheel || format == .slotMachine {
            for rawSlot in config.objectArray("slots") {
                guard let outcomeKey = rawSlot.nonBlankString("outcomeKey") else {
                    log.d("Gamification slot dropped — missing outcomeKey")
                    continue
                }
                var slotValues: [String: String] = [:]
                for (key, raw) in (rawSlot["values"] as? [String: Any]) ?? [:] {
                    guard let string = raw as? String else {
                        log.d("Gamification slot value dropped — not a string (key=\(key))")
                        continue
                    }
                    slotValues[key] = string
                }
                slots.append(GamificationSlotConfig(outcomeKey: outcomeKey, values: slotValues))
            }
        }

        return GamificationConfig(
            skinId: skinId,
            skinVersion: skinVersion,
            bridgeVersion: positiveInt(templateConfig["bridgeVersion"]),
            format: format,
            values: values,
            slots: slots,
            entryKind: entryKind,
            surfaceStyle: surfaceStyle,
            showMute: surface?.bool("showMute", default: false) ?? false,
            bundleUrl: bundleUrl,
            sensors: sensors,
            slotKey: templateConfig.nonBlankString("slotKey")
        )
    }

    /// A positive integer that is not a boolean: JSON booleans bridge to
    /// `NSNumber`, so a bare `as? Int` would read `true` as `1`.
    private static func positiveInt(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let value = number.intValue
        return value > 0 ? value : nil
    }
}
