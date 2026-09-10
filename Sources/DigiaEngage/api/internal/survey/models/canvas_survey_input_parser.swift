import Foundation

struct CanvasSurveyInputParser {
    var designTokens: DesignTokenCatalog = .empty

    func parse(_ json: [String: JSONValue]?, requiredFallback: Bool = false) -> CanvasSurveyWireInput? {
        guard let json else { return nil }
        let type = inputType(firstNonBlank(
            SurveyParse.string(json["type"]),
            SurveyParse.string(json["inputType"])
        ))
        let style = inputStyle(SurveyParse.object(json["style"]))
        let required = SurveyParse.bool(json["required"]) ?? requiredFallback
        switch profile(for: type) {
        case .choice:
            return .choice(CanvasSurveyChoiceInput(
                type: type,
                required: required,
                style: style,
                options: options(SurveyParse.array(json["options"])),
                maximumSelections: maxSelections(json),
                optionStyleMode: SurveyParse.string(json["optionStyleMode"]) == "individual" ? .individual : .shared,
                sharedText: nil
            ))
        case .field:
            return .field(CanvasSurveyFieldInput(
                type: type,
                required: required,
                style: style,
                placeholder: SurveyParse.string(json["placeholder"]) ?? "",
                dateFormat: dateFormat(SurveyParse.string(json["dateFormat"])),
                defaultDate: SurveyParse.string(json["defaultDate"]),
                minimumDate: SurveyParse.string(json["minimumDate"]),
                maximumDate: SurveyParse.string(json["maximumDate"]),
                minLength: canvasSurveyInt(json["minLength"]),
                maxLength: canvasSurveyInt(json["maxLength"]),
                minimum: canvasSurveyDouble(json["minimum"]) ?? canvasSurveyDouble(json["min"]),
                maximum: canvasSurveyDouble(json["maximum"]) ?? canvasSurveyDouble(json["max"]),
                multilineRows: min(8, max(1, canvasSurveyInt(json["multilineRows"]) ?? 1))
            ))
        case .scale:
            return .scale(CanvasSurveyScaleInput(
                type: type,
                required: required,
                style: style,
                minimum: canvasSurveyDouble(json["minimum"]) ?? canvasSurveyDouble(json["min"]) ?? 1,
                maximum: canvasSurveyDouble(json["maximum"]) ?? canvasSurveyDouble(json["max"]) ?? 5,
                step: canvasSurveyDouble(json["step"]) ?? 1,
                symbolSize: CGFloat(min(96, max(0, canvasSurveyDouble(json["symbolSize"]) ?? 0))),
                numericNpsVariant: SurveyParse.string(json["numericNpsVariant"]) == "circle" ? .circle : .rounded
            ))
        }
    }

    private func inputStyle(_ json: [String: JSONValue]?) -> CanvasSurveyInputStyle {
        let style = json ?? [:]
        return CanvasSurveyInputStyle(
            layout: choiceLayout(SurveyParse.string(style["layout"])),
            columns: min(4, max(1, canvasSurveyInt(style["columns"]) ?? 1)),
            itemGap: CGFloat(min(64, max(0, canvasSurveyDouble(style["itemGap"]) ?? 8))),
            fontSize: CGFloat(min(64, max(8, canvasSurveyDouble(style["fontSize"]) ?? 15))),
            fontWeight: fontWeight(style["fontWeight"], default: 500),
            textColor: color(style["textColor"], fallback: "#FF18181B"),
            selectedTextColor: color(style["selectedTextColor"], fallback: "#FFFFFFFF"),
            selectedFill: color(style["selectedFill"], fallback: "#FF4945FF"),
            unselectedFill: color(style["unselectedFill"], fallback: "#FFFFFFFF"),
            selectedBorderColor: color(style["selectedBorderColor"], fallback: "#FF4945FF"),
            borderColor: color(style["borderColor"], fallback: "#FFE4E4E7"),
            borderWidth: CGFloat(min(16, max(0, canvasSurveyDouble(style["borderWidth"]) ?? 1))),
            cornerRadius: CGFloat(min(999, max(0, canvasSurveyDouble(style["cornerRadius"]) ?? 12))),
            padding: CGFloat(min(64, max(0, canvasSurveyDouble(style["padding"]) ?? 12)))
        )
    }

    private func options(_ raw: [JSONValue]?) -> [CanvasSurveyOption] {
        (raw ?? []).compactMap { value in
            guard let option = SurveyParse.object(value) else { return nil }
            let id = firstNonBlank(
                SurveyParse.string(option["id"]),
                SurveyParse.string(option["value"])
            )
            guard !id.isEmpty else { return nil }
            return CanvasSurveyOption(
                id: id,
                label: firstNonBlank(
                    SurveyParse.string(option["label"]),
                    SurveyParse.string(option["text"]),
                    SurveyParse.string(option["value"]),
                    id
                )
            )
        }
    }

    private func inputType(_ value: String) -> CanvasSurveyInputType {
        switch normalise(value) {
        case "multi_select", "multiple_choice", "multi": return .multiSelect
        case "upvote": return .upvote
        case "short_text", "shorttext": return .shortText
        case "long_text", "longtext": return .longText
        case "number": return .number
        case "email": return .email
        case "date": return .date
        case "rating": return .rating
        case "reaction": return .reaction
        case "numeric_nps", "nps": return .numericNps
        default: return .singleSelect
        }
    }

    private func profile(for type: CanvasSurveyInputType) -> CanvasSurveyInputProfile {
        switch type {
        case .singleSelect, .multiSelect, .upvote: return .choice
        case .shortText, .longText, .number, .email, .date: return .field
        case .rating, .reaction, .numericNps: return .scale
        }
    }

    private func choiceLayout(_ value: String?) -> CanvasSurveyChoiceLayout {
        switch value {
        case "row": return .row
        case "grid": return .grid
        default: return .list
        }
    }

    private func dateFormat(_ value: String?) -> CanvasSurveyDateFormat {
        switch value {
        case "mm_dd_yyyy": return .mmDdYyyy
        case "yyyy_mm_dd": return .yyyyMmDd
        default: return .ddMmYyyy
        }
    }

    private func color(_ value: JSONValue?, fallback: String) -> CampaignColor {
        (try? designTokens.resolveColor(canvasSurveyJsonAny(value)))
            ?? canonicalCampaignColorHex(unwrapLiteral(canvasSurveyJsonAny(value))).map(CampaignColor.literal)
            ?? .literal(fallback)
    }

    private func fontWeight(_ value: JSONValue?, default fallback: Int) -> Int {
        guard let value = unwrapLiteral(canvasSurveyJsonAny(value)), !(value is NSNull) else { return fallback }
        if let string = value as? String, string.lowercased().hasPrefix("w") {
            return DigiaFontWeight.optional(String(string.dropFirst())) ?? fallback
        }
        return DigiaFontWeight.optional(value) ?? fallback
    }

    private func maxSelections(_ json: [String: JSONValue]) -> Int? {
        intForAnyKey(
            in: json,
            keys: [
                "maximumSelections",
                "maxSelections",
                "maximumSelection",
                "maxSelection",
                "maxselection",
                "maximum_selection",
                "max_selection",
            ]
        ).map { min(100, max(1, $0)) }
    }

    private func intForAnyKey(in json: [String: JSONValue], keys: Set<String>) -> Int? {
        let normalizedKeys = Set(keys.map(normalizedKey))
        for (key, value) in json where normalizedKeys.contains(normalizedKey(key)) {
            if let intValue = canvasSurveyInt(value) {
                return intValue
            }
        }
        for containerKey in ["validation", "constraints", "limits", "rules"] {
            if let nested = SurveyParse.object(json[containerKey]),
               let intValue = intForAnyKey(in: nested, keys: keys) {
                return intValue
            }
        }
        return nil
    }

    private func firstNonBlank(_ values: String?...) -> String {
        values.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    private func normalise(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}

private func canvasSurveyDouble(_ value: JSONValue?) -> Double? {
    guard let number = designNumber(unwrapLiteral(canvasSurveyJsonAny(value))), number.isFinite else {
        return nil
    }
    return number
}

private func canvasSurveyInt(_ value: JSONValue?) -> Int? {
    canvasSurveyDouble(value).map(Int.init)
}
