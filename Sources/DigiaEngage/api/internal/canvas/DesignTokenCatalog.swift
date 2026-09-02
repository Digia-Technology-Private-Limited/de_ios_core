import Foundation

enum DesignTokenError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

struct DesignTokenCatalog {
    private let colors: [String: CampaignColor]
    private let typography: [String: CampaignTypography]
    static let empty = DesignTokenCatalog(colors: [:], typography: [:])

    static func fromJson(_ json: [String: Any]) throws -> DesignTokenCatalog {
        let supported = json["supportedThemes"] as? [String] ?? []
        let themes = json["themes"] as? [String: Any] ?? [:]
        let effective: [String]
        switch supported.count {
        case 0: effective = []
        case 1: effective = [supported[0], supported[0]]
        default:
            guard supported.contains("light"), supported.contains("dark") else {
                throw DesignTokenError.invalid("Multiple themes require light and dark")
            }
            effective = ["light", "dark"]
        }
        let light = effective.isEmpty ? [:] : try themeColors(themes, theme: effective[0])
        let dark = effective.isEmpty ? [:] : try themeColors(themes, theme: effective[1])
        var colors: [String: CampaignColor] = [:]
        for id in Set(light.keys).union(dark.keys) {
            let lightHex = canonicalCampaignColorHex(unwrapLiteral(light[id]))
            let darkHex = canonicalCampaignColorHex(unwrapLiteral(dark[id]))
            if let resolvedLight = lightHex ?? darkHex,
               let resolvedDark = darkHex ?? lightHex {
                colors[id] = CampaignColor(lightHex: resolvedLight, darkHex: resolvedDark)
            }
        }
        var typography: [String: CampaignTypography] = [:]
        for entry in json["typography"] as? [[String: Any]] ?? [] {
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let value = unwrapLiteral(entry["value"]) as? [String: Any] else { continue }
            typography[id] = parseTypography(value)
        }
        return DesignTokenCatalog(colors: colors, typography: typography)
    }

    func resolveColor(_ property: Any?) throws -> CampaignColor? {
        guard let value = unwrapLiteral(property), !(value is NSNull) else { return nil }
        if let map = value as? [String: Any] {
            guard let token = map["token"] as? String, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return colors[token]
        }
        return canonicalCampaignColorHex(value).map(CampaignColor.literal)
    }

    func resolveTypography(
        _ property: Any?,
        fallbackOnMissingToken: Bool = false
    ) throws -> CampaignTypography? {
        guard let value = unwrapLiteral(property), !(value is NSNull) else { return nil }
        guard let map = value as? [String: Any] else { throw DesignTokenError.invalid("Invalid typography property") }
        if let token = exactToken(map) {
            if let result = typography[token] { return result }
            guard fallbackOnMissingToken else {
                throw DesignTokenError.invalid("Unknown typography token '\(token)'")
            }
            DigiaLog.warning("Unknown typography token '\(token)'; using the default typography")
            return nil
        }
        if map["token"] != nil { throw DesignTokenError.invalid("Ambiguous typography property") }
        return Self.parseTypography(map)
    }

    private static func themeColors(_ themes: [String: Any], theme: String) throws -> [String: Any] {
        guard let value = themes[theme] as? [String: Any] else { throw DesignTokenError.invalid("Missing '\(theme)' theme") }
        var result: [String: Any] = [:]
        for entry in value["colors"] as? [[String: Any]] ?? [] {
            if let id = entry["id"] as? String, !id.isEmpty { result[id] = entry["value"] }
        }
        return result
    }

    private static func parseTypography(_ json: [String: Any]) -> CampaignTypography {
        CampaignTypography(
            fontFamily: unwrapLiteral(json["fontFamily"]) as? String,
            fontSize: designNumber(unwrapLiteral(json["fontSize"])).map { CGFloat($0) },
            fontWeight: fontWeight(unwrapLiteral(json["fontWeight"])),
            lineHeight: designNumber(unwrapLiteral(json["lineHeight"])).map { CGFloat($0) },
            letterSpacing: designNumber(unwrapLiteral(json["letterSpacing"])).map { CGFloat($0) }
        )
    }

    private static func fontWeight(_ raw: Any?) -> Int? {
        guard let raw else { return nil }
        let value: Any
        if let string = raw as? String, string.lowercased().hasPrefix("w") { value = String(string.dropFirst()) }
        else { value = raw }
        return DigiaFontWeight.optional(value)
    }
}

func unwrapLiteral(_ raw: Any?) -> Any? {
    var value = raw
    while let map = value as? [String: Any], map.count == 1, map.keys.first == "value" { value = map["value"] }
    return value
}

func exactToken(_ map: [String: Any]) -> String? {
    guard map.count == 1, let token = map["token"] as? String, !token.isEmpty else { return nil }
    return token
}

func designNumber(_ raw: Any?) -> Double? {
    switch raw { case let value as NSNumber: value.doubleValue; case let value as String: Double(value.trimmingCharacters(in: .whitespaces)); default: nil }
}

func canonicalCampaignColorHex(_ raw: Any?) -> String? {
    guard var value = raw as? String else { return nil }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard value.first == "#" else { return nil }
    value.removeFirst()
    if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
    if value.count == 6 { value = "FF" + value }
    guard value.count == 8, value.allSatisfy({ $0.isHexDigit }) else { return nil }
    return "#" + value
}
