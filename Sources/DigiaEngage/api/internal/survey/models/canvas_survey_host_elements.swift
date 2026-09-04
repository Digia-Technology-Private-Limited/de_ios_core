import Foundation

typealias CanvasSurveyHostElementCodec = (
    _ id: String,
    _ rect: CampaignCanvasRect,
    _ props: [String: JSONValue],
    _ context: CanvasSurveyParseContext
) -> CanvasSurveyHostElement?

struct CanvasSurveyParseContext {
    let designTokens: DesignTokenCatalog

    func color(_ value: JSONValue?, fallback: String) -> CampaignColor {
        (try? designTokens.resolveColor(canvasSurveyJsonAny(value)))
            ?? canonicalCampaignColorHex(unwrapLiteral(canvasSurveyJsonAny(value))).map(CampaignColor.literal)
            ?? .literal(fallback)
    }
}

struct CanvasSurveyHostElementCodecRegistry {
    var codecs: [String: CanvasSurveyHostElementCodec] = [
        "canvasSurvey.answerInput": answerInput,
        "canvasSurvey.managed": managed,
    ]

    func parse(
        _ child: [String: JSONValue],
        canvasWidth: CGFloat,
        canvasHeight: CGFloat,
        context: CanvasSurveyParseContext
    ) -> CanvasSurveyHostElement? {
        guard SurveyParse.string(child["kind"]) == "hostElement",
              let element = SurveyParse.object(child["element"]),
              let rectJson = SurveyParse.object(child["rect"]),
              let codec = codecs[SurveyParse.string(element["type"]) ?? ""] else { return nil }
        return codec(
            SurveyParse.string(child["id"]) ?? "",
            rect(rectJson, canvasWidth: canvasWidth, canvasHeight: canvasHeight),
            SurveyParse.object(element["props"]) ?? [:],
            context
        )
    }
}

private func answerInput(
    id: String,
    rect: CampaignCanvasRect,
    props: [String: JSONValue],
    context: CanvasSurveyParseContext
) -> CanvasSurveyHostElement {
    .answer(CanvasSurveyAnswerHostElement(
        id: id,
        rect: rect,
        presentationStyle: surveyInputStyle(SurveyParse.object(props["style"]), context: context),
        optionPresentations: optionPresentations(SurveyParse.array(props["options"]), context: context),
        optionStyleModeOverride: props["optionStyleMode"] == nil ? nil : optionStyleMode(props),
        sharedText: optionText(SurveyParse.object(props["text"]), context: context),
        maximumSelectionsOverride: maxSelections(props),
        symbolSize: min(96, max(0, CGFloat(canvasSurveyDouble(props["symbolSize"]) ?? 0))),
        numericNpsVariant: SurveyParse.string(props["numericNpsVariant"]) == "circle" ? .circle : .rounded
    ))
}

private func managed(
    id: String,
    rect: CampaignCanvasRect,
    props: [String: JSONValue],
    context: CanvasSurveyParseContext
) -> CanvasSurveyHostElement? {
    guard let role = managedRole(SurveyParse.string(props["role"])) else { return nil }
    return .managed(CanvasSurveyManagedHostElement(
        id: id,
        rect: rect,
        role: role,
        visible: SurveyParse.bool(props["visible"]) ?? true,
        label: SurveyParse.string(props["label"]) ?? "",
        doneLabel: SurveyParse.string(props["doneLabel"]) ?? "",
        colorHex: colorHex(props["color"], designTokens: context.designTokens, fallback: "#FF18181B"),
        fillHex: colorHex(props["fill"], designTokens: context.designTokens, fallback: "#FFF4F4F5"),
        trackColorHex: colorHex(props["trackColor"], designTokens: context.designTokens, fallback: "#FFE5E7EB"),
        borderColorHex: colorHex(props["borderColor"], designTokens: context.designTokens, fallback: "#00000000"),
        borderWidth: CGFloat(max(0, canvasSurveyDouble(props["borderWidth"]) ?? 0)),
        cornerRadius: CGFloat(max(0, canvasSurveyDouble(props["cornerRadius"]) ?? 999)),
        fontSize: CGFloat(min(64, max(8, canvasSurveyDouble(props["fontSize"]) ?? 14))),
        gap: CGFloat(min(64, max(0, canvasSurveyDouble(props["gap"]) ?? 4))),
        padding: CGFloat(min(64, max(0, canvasSurveyDouble(props["padding"]) ?? 6))),
        progressStyle: SurveyParse.string(props["progressStyle"]) ?? "segmented",
        countQuestionsOnly: SurveyParse.bool(props["countQuestionsOnly"]) ?? true,
        iconColorHex: props["iconColor"] == nil
            ? nil
            : colorHex(props["iconColor"], designTokens: context.designTokens, fallback: "#FF18181B"),
        iconSize: CGFloat(min(96, max(0, canvasSurveyDouble(props["iconSize"]) ?? 0))),
        button: managedButton(SurveyParse.object(props["button"]), role: role, designTokens: context.designTokens)
    ))
}

private func rect(
    _ json: [String: JSONValue],
    canvasWidth: CGFloat,
    canvasHeight: CGFloat
) -> CampaignCanvasRect {
    CampaignCanvasRect(
        x: CGFloat(canvasSurveyDouble(json["x"]) ?? 0) * canvasWidth,
        y: CGFloat(canvasSurveyDouble(json["y"]) ?? 0) * canvasHeight,
        width: max(0, CGFloat(canvasSurveyDouble(json["width"]) ?? 0) * canvasWidth),
        height: max(0, CGFloat(canvasSurveyDouble(json["height"]) ?? 0) * canvasHeight)
    )
}

private func managedButton(
    _ button: [String: JSONValue]?,
    role: CanvasSurveyManagedRole,
    designTokens: DesignTokenCatalog
) -> CampaignCanvasWidget? {
    guard let button else { return nil }
    var props = canvasSurveyJsonObject(SurveyParse.object(button["props"]) ?? [:])
    props["onClick"] = normalizedAction(props["onClick"], role: role)
    var widget: [String: Any] = [
        "type": "digia/button",
        "props": props,
    ]
    if let common = SurveyParse.object(button["common"]) {
        widget["containerProps"] = canvasSurveyJsonObject(common)
    }
    let canvas: [String: Any] = [
        "version": 2,
        "canvasWidth": 1,
        "canvasHeight": 1,
        "children": [[
            "kind": "widget",
            "id": SurveyParse.string(button["id"]) ?? "canvas_survey_button",
            "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
            "widget": widget,
        ]],
    ]
    guard let parsed = try? CampaignCanvasParser(designTokens: designTokens).parse(canvas),
          case .widget(_, _, let parsedWidget) = parsed.children.first,
          case .button = parsedWidget else { return nil }
    return parsedWidget
}

private func normalizedAction(_ raw: Any?, role: CanvasSurveyManagedRole) -> [String: Any] {
    if let raw = raw as? [String: Any] { return raw }
    var steps = (raw as? [[String: Any]]) ?? []
    if steps.isEmpty {
        let type: String
        switch role {
        case .backNavigation: type = "previous"
        case .dismiss: type = "dismiss"
        default: type = "next"
        }
        steps.append(["type": type])
    }
    return ["steps": steps]
}

private func optionPresentations(
    _ options: [JSONValue]?,
    context: CanvasSurveyParseContext
) -> [String: CanvasSurveyOptionPresentation] {
    var result: [String: CanvasSurveyOptionPresentation] = [:]
    for value in options ?? [] {
        guard let option = SurveyParse.object(value),
              let id = SurveyParse.nonBlank(option["id"]) else { continue }
        result[id] = CanvasSurveyOptionPresentation(
            text: optionText(SurveyParse.object(option["text"]), context: context),
            styleOverride: surveyInputStyleOverride(SurveyParse.object(option["style"]), context: context)
        )
    }
    return result
}

private func optionText(
    _ json: [String: JSONValue]?,
    context: CanvasSurveyParseContext
) -> CanvasSurveyOptionText? {
    guard let json else { return nil }
    let textBlock = SurveyParse.object(json["text"]) ?? json
    guard let span = (SurveyParse.array(textBlock["spans"]) ?? [])
        .compactMap(SurveyParse.object)
        .first else { return nil }
    let text = SurveyParse.string(span["text"]) ?? ""
    let typography = unwrapLiteral(canvasSurveyJsonAny(span["typography"])) as? [String: Any] ?? [:]
    let fontSize = designNumber(unwrapLiteral(typography["fontSize"])).map { CGFloat($0) }
    let fontWeight = optionalFontWeight(typography["fontWeight"])
    let color = try? context.designTokens.resolveColor(canvasSurveyJsonAny(span["color"]))
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       fontSize == nil,
       fontWeight == nil,
       color == nil {
        return nil
    }
    return CanvasSurveyOptionText(
        text: text,
        typography: CampaignTypography(
            fontSize: fontSize,
            fontWeight: fontWeight
        ),
        color: color
    )
}

private func surveyInputStyle(
    _ json: [String: JSONValue]?,
    context: CanvasSurveyParseContext
) -> CanvasSurveyInputStyle {
    let style = json ?? [:]
    return CanvasSurveyInputStyle(
        layout: choiceLayout(SurveyParse.string(style["layout"])),
        columns: min(4, max(1, canvasSurveyInt(style["columns"]) ?? 1)),
        itemGap: CGFloat(min(64, max(0, canvasSurveyDouble(style["itemGap"]) ?? 8))),
        fontSize: CGFloat(min(64, max(8, canvasSurveyDouble(style["fontSize"]) ?? 15))),
        fontWeight: fontWeight(style["fontWeight"], default: 500),
        textColor: context.color(style["textColor"], fallback: "#FF18181B"),
        selectedTextColor: context.color(style["selectedTextColor"], fallback: "#FFFFFFFF"),
        selectedFill: context.color(style["selectedFill"], fallback: "#FF4945FF"),
        unselectedFill: context.color(style["unselectedFill"], fallback: "#FFFFFFFF"),
        selectedBorderColor: context.color(style["selectedBorderColor"], fallback: "#FF4945FF"),
        borderColor: context.color(style["borderColor"], fallback: "#FFE4E4E7"),
        borderWidth: CGFloat(min(16, max(0, canvasSurveyDouble(style["borderWidth"]) ?? 1))),
        cornerRadius: CGFloat(min(999, max(0, canvasSurveyDouble(style["cornerRadius"]) ?? 12))),
        padding: CGFloat(min(64, max(0, canvasSurveyDouble(style["padding"]) ?? 12)))
    )
}

private func surveyInputStyleOverride(
    _ json: [String: JSONValue]?,
    context: CanvasSurveyParseContext
) -> CanvasSurveyInputStyleOverride {
    let style = json ?? [:]
    return CanvasSurveyInputStyleOverride(
        layout: style["layout"] == nil ? nil : choiceLayout(SurveyParse.string(style["layout"])),
        columns: style["columns"].flatMap(canvasSurveyInt),
        itemGap: style["itemGap"].flatMap(canvasSurveyDouble).map { CGFloat($0) },
        fontSize: style["fontSize"].flatMap(canvasSurveyDouble).map { CGFloat($0) },
        fontWeight: style["fontWeight"].map { fontWeight($0, default: 500) },
        textColor: style["textColor"].map { context.color($0, fallback: "#00000000") },
        selectedTextColor: style["selectedTextColor"].map { context.color($0, fallback: "#00000000") },
        selectedFill: style["selectedFill"].map { context.color($0, fallback: "#00000000") },
        unselectedFill: style["unselectedFill"].map { context.color($0, fallback: "#00000000") },
        selectedBorderColor: style["selectedBorderColor"].map { context.color($0, fallback: "#00000000") },
        borderColor: style["borderColor"].map { context.color($0, fallback: "#00000000") },
        borderWidth: style["borderWidth"].flatMap(canvasSurveyDouble).map { CGFloat($0) },
        cornerRadius: style["cornerRadius"].flatMap(canvasSurveyDouble).map { CGFloat($0) },
        padding: style["padding"].flatMap(canvasSurveyDouble).map { CGFloat($0) }
    )
}

private func optionStyleMode(_ props: [String: JSONValue]) -> CanvasSurveyOptionStyleMode {
    SurveyParse.string(props["optionStyleMode"]) == "individual" ? .individual : .shared
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

private func normalizedKey(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
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

private func choiceLayout(_ value: String?) -> CanvasSurveyChoiceLayout {
    switch value {
    case "row": return .row
    case "grid": return .grid
    default: return .list
    }
}

private func managedRole(_ role: String?) -> CanvasSurveyManagedRole? {
    switch role {
    case "progress": return .progress
    case "pageCount": return .pageCount
    case "timer": return .timer
    case "primaryNavigation": return .primaryNavigation
    case "backNavigation": return .backNavigation
    case "dismiss": return .dismiss
    default: return nil
    }
}

private func colorHex(
    _ value: JSONValue?,
    designTokens: DesignTokenCatalog,
    fallback: String
) -> String {
    (try? designTokens.resolveColor(canvasSurveyJsonAny(value)))?.lightHex
        ?? canonicalCampaignColorHex(unwrapLiteral(canvasSurveyJsonAny(value)))
        ?? fallback
}

private func fontWeight(_ value: JSONValue?, default fallback: Int) -> Int {
    optionalFontWeight(canvasSurveyJsonAny(value)) ?? fallback
}

private func optionalFontWeight(_ raw: Any?) -> Int? {
    guard let value = unwrapLiteral(raw), !(value is NSNull) else { return nil }
    if let string = value as? String, string.lowercased().hasPrefix("w") {
        return DigiaFontWeight.optional(String(string.dropFirst()))
    }
    return DigiaFontWeight.optional(value)
}

func canvasSurveyJsonObject(_ json: [String: JSONValue]) -> [String: Any] {
    json.mapValues(canvasSurveyJsonAny)
}

func canvasSurveyJsonAny(_ value: JSONValue?) -> Any {
    guard let value else { return NSNull() }
    switch value {
    case .string(let value): return value
    case .int(let value): return value
    case .double(let value): return value
    case .bool(let value): return value
    case .array(let value): return value.map(canvasSurveyJsonAny)
    case .object(let value): return canvasSurveyJsonObject(value)
    case .null: return NSNull()
    }
}
