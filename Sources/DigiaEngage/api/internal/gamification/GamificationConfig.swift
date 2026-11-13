import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

struct GamificationSlotConfig: Equatable, Sendable {
    let outcomeKey: String
    let values: [String: String]
}

/// The entry canvas of a non-direct campaign: the card the host draws in an
/// inline slot, or the window the story floater draws over the app. Either
/// way its tap runs canvas actions, and `Action.openGame` opens the game.
enum GamificationEntryCanvas: Equatable {
    case inline(InlineCanvasConfig)
    case floating(FloaterStoryConfig)
}

/// A parsed gamification campaign: the skin reference, its config, and how
/// the player gets to the full-screen game. Parsed in `CampaignModel.fromJson`
/// ("gamification"). A nil return skips the campaign; `CampaignBundle` already
/// logs every skip with the campaign key, so no log here.
struct GamificationConfig: Equatable {
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
    /// Never `.unknown`: an unrecognised or missing entry opens the game directly.
    let entryKind: GamificationEntryKind
    /// The entry canvas for `inlineTeaser` / `floating`; nil for `direct`.
    let entryCanvas: GamificationEntryCanvas?
    let showMute: Bool
    let bundleUrl: String
    let sensors: [GamificationSkinSensor]
    /// The inline slot of the `inlineTeaser` entry.
    let slotKey: String?
    /// Reward `ctaText` from `templateConfig.rewards`, keyed by `rewardId`.
    let rewardCtaTexts: [String: String]

    /// Only `spinWheel` and `slotMachine` map slots; the ERD leaves `slots`
    /// out of `init` for `scratchCard` and `rewardChest`.
    var usesSlots: Bool {
        format == .spinWheel || format == .slotMachine
    }

    /// `templateConfig` is the campaign's own; `campaignLevel` is the campaign
    /// object, read only for `bundleUrl`/`sensors` as a fallback — the backend
    /// adds them next to `templateConfig`, and either placement is accepted.
    static func fromJson(
        _ templateConfig: [String: Any], campaignLevel: [String: Any]? = nil,
        designTokens: DesignTokenCatalog = .empty
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

        // `entry` is `{ kind }` on the wire; a bare string is accepted too. An
        // unknown or missing kind degrades to a direct open — never a failure.
        let entryKind = entryKind(templateConfig["entry"])
        // The surface is always full screen; any legacy `surface.style` is ignored.
        let surface = templateConfig.object("surface")
        let slotKey = templateConfig.nonBlankString("slotKey")

        var entryCanvas: GamificationEntryCanvas?
        switch entryKind {
        case .inlineTeaser, .floating:
            entryCanvas = parseEntryCanvas(
                kind: entryKind, templateConfig: templateConfig, slotKey: slotKey,
                designTokens: designTokens)
            // No readable entry canvas means the player has nothing to tap.
            guard entryCanvas != nil else {
                log.w("Gamification campaign skipped — entry canvas unreadable (entry=\(entryKind.rawValue))")
                return nil
            }
        case .direct, .unknown:
            break
        }

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
            entryCanvas: entryCanvas,
            showMute: surface?.bool("showMute", default: false) ?? false,
            bundleUrl: bundleUrl,
            sensors: sensors,
            slotKey: slotKey,
            rewardCtaTexts: rewardCtaTexts(templateConfig: templateConfig)
        )
    }

    /// `templateConfig.rewards`, a sibling of `bundleUrl`: a list of
    /// `{ rewardId, ctaText }`. Entries missing either field are skipped, so the
    /// skin falls back to "Use now". No other shape is read.
    private static func rewardCtaTexts(templateConfig: [String: Any]) -> [String: String] {
        var texts: [String: String] = [:]
        for reward in templateConfig.objectArray("rewards") {
            guard let rewardId = reward.nonBlankString("rewardId"),
                  let text = reward.nonBlankString("ctaText")
            else { continue }
            texts[rewardId] = text
        }
        return texts
    }

    private static func entryKind(_ raw: Any?) -> GamificationEntryKind {
        let wire = (raw as? [String: Any])?.string("kind") ?? (raw as? String)
        let kind = GamificationEntryKind(wire: wire)
        return kind == .unknown ? .direct : kind
    }

    /// The teaser is the entry's canvas design, in the same shape the canvas
    /// editor saves for the matching surface: an inline card for `inlineTeaser`,
    /// a floater window for `floating`. The floater placement (`collapsed`,
    /// `controls`, `behavior`, `designWidth`) may sit on `templateConfig` or on
    /// the teaser; the teaser wins. A floating entry opens no story, so its
    /// tap runs canvas actions instead.
    private static func parseEntryCanvas(
        kind: GamificationEntryKind,
        templateConfig: [String: Any],
        slotKey: String?,
        designTokens: DesignTokenCatalog
    ) -> GamificationEntryCanvas? {
        guard let teaser = templateConfig.object("teaser"), teaser.object("canvas") != nil
        else { return nil }
        switch kind {
        case .inlineTeaser:
            var json = teaser
            if json.nonBlankString("slotKey") == nil, let slotKey { json["slotKey"] = slotKey }
            guard var config = (try? InlineCanvasConfig.fromJson(json, designTokens: designTokens)) ?? nil
            else { return nil }
            config.variableSchemas = NudgeConfig.parseVariableSchemas(templateConfig)
            return .inline(config)
        case .floating:
            var json = teaser
            for key in ["designWidth", "collapsed", "controls", "behavior"]
            where json[key] == nil {
                json[key] = templateConfig[key]
            }
            guard let config = (try? FloaterStoryConfig.fromJson(
                json, designTokens: designTokens, requiresStory: false)) ?? nil
            else { return nil }
            return .floating(config)
        case .direct, .unknown:
            return nil
        }
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
