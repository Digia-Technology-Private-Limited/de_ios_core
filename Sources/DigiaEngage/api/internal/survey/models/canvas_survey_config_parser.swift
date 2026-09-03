import Foundation

extension SurveyBlockType {
    static func canvasQuestionType(_ value: String?) -> SurveyBlockType? {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "single_select": return .singleSelect
        case "multi_select": return .multiSelect
        case "upvote": return .upvote
        case "short_text": return .shortText
        case "long_text": return .longText
        case "number": return .number
        case "email": return .email
        case "date": return .date
        case "rating": return .rating
        case "reaction": return .reaction
        case "numeric_nps": return .nps
        case "nps_emoji": return .npsEmoji
        case "nps_smiley": return .npsSmiley
        case "this_or_that": return .thisOrThat
        case "tier_list": return .tierList
        default: return nil
        }
    }
}

enum CanvasSurveyConfigParser {
    private enum SceneKind {
        case question
        case content
        case result
    }

    static func from(
        _ json: [String: JSONValue],
        fallbackId: String,
        designTokens: DesignTokenCatalog = .empty
    ) -> SurveyConfigModel? {
        guard SurveyParse.string(json["templateType"]) == "survey",
              let scenesArr = SurveyParse.array(json["scenes"]),
              let flow = SurveyParse.object(json["flow"]),
              let flowNodesArr = SurveyParse.array(flow["nodes"]) else { return nil }
        let welcome = SurveyParse.object(json["welcome"]).flatMap(welcomeBlock)
        let sceneBlocks = scenesArr
            .compactMap { SurveyParse.object($0) }
            .compactMap { sceneBlock($0, designTokens: designTokens) }
        let blocks = [welcome].compactMap { $0 } + sceneBlocks
        let sceneIds = Set(sceneBlocks.map(\.id))
        let nodes = flowNodesArr.compactMap { value -> SurveyNode? in
            guard let node = SurveyParse.object(value),
                  let id = SurveyParse.nonBlank(node["id"]),
                  let sceneId = SurveyParse.nonBlank(node["sceneId"]),
                  sceneIds.contains(sceneId) else { return nil }
            return SurveyNode(id: id, blockId: sceneId, branching: nodeBranching(node))
        }
        guard !sceneBlocks.isEmpty, !nodes.isEmpty else { return nil }

        let rootNodeIdRaw = SurveyParse.nonBlank(flow["rootNodeId"])
        let rootNodeId = (rootNodeIdRaw.map { id in nodes.contains { $0.id == id } } == true)
            ? rootNodeIdRaw : nodes.first?.id
        let rootSceneId = nodes.first { $0.id == rootNodeId }?.blockId
        let name = SurveyParse.firstNonEmptyOptional(
            SurveyParse.string(json["name"]),
            SurveyParse.string(json["surveyName"]),
            SurveyParse.string(json["title"])
        )
        return SurveyConfigModel(
            id: SurveyParse.firstNonEmpty(
                SurveyParse.string(json["id"]),
                SurveyParse.string(json["_id"]),
                SurveyParse.string(json["templateId"]),
                fallbackId
            ),
            name: name,
            blocks: blocks,
            nodes: nodes,
            rootNodeId: rootNodeId,
            settings: settings(json),
            theme: SurveyTheme.from(SurveyParse.object(json["theme"])),
            uiTemplateId: SurveyParse.nonBlank(json["uiTemplateId"]),
            timeDelayMs: max(0, min(10_000, SurveyParse.int(json["timeDelayMs"]) ?? 0)),
            canvasSurvey: CanvasSurveyConfig(
                designWidth: designWidth(json),
                welcomeDocument: welcomeDocument(json, designTokens: designTokens),
                scenesByBlockId: sceneDocuments(
                    scenesArr,
                    root: json,
                    designTokens: designTokens,
                    fallbackDesignWidth: designWidth(json),
                    rootSceneId: rootSceneId,
                    canNavigateBackFromRoot: welcome != nil
                )
            )
        )
    }

    private static func welcomeBlock(_ json: [String: JSONValue]) -> SurveyBlock? {
        guard SurveyParse.bool(json["enabled"]) ?? false else { return nil }
        return SurveyBlock(
            id: SurveyParse.nonBlank(json["id"]) ?? "canvas_welcome",
            type: .welcome,
            title: RichText(text: canvasTitle(json, fallback: "Welcome")),
            body: nil,
            options: [],
            optionStyle: nil,
            npsStyle: nil,
            required: false,
            hidden: false,
            showMedia: false,
            media: .empty,
            showTag: false,
            showAnswerMedia: false,
            showAnswerDescriptions: false,
            shuffle: false,
            allowOther: false,
            answerLayout: .column,
            backgroundColor: "",
            numberMin: nil,
            numberMax: nil,
            showWhen: nil
        )
    }

    private static func sceneBlock(
        _ json: [String: JSONValue],
        designTokens: DesignTokenCatalog
    ) -> SurveyBlock? {
        guard let id = SurveyParse.nonBlank(json["id"]),
              SurveyParse.bool(json["enabled"]) ?? true else { return nil }
        let kind = sceneKind(SurveyParse.string(json["kind"]) ?? "question")
        let input = SurveyParse.object(json["input"])
        let inputType = input.flatMap { SurveyParse.string($0["type"]) }
        let type: SurveyBlockType?
        switch kind {
        case .question: type = SurveyBlockType.canvasQuestionType(inputType) ?? SurveyParse.blockType(inputType)
        case .result: type = .resultPage
        case .content: type = .textMedia
        }
        guard let type else { return nil }
        let answerPresentation = answerPresentation(json)
        let parsedOptions = (input.flatMap { SurveyParse.array($0["options"]) } ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap(SurveyOption.from)
        return SurveyBlock(
            id: id,
            type: type,
            title: RichText(text: sceneTitle(json)),
            body: nil,
            options: parsedOptions.isEmpty ? SurveyParse.fallbackOptions(for: type) : parsedOptions,
            optionStyle: inputStyle(answerPresentation, designTokens: designTokens),
            npsStyle: npsStyle(input, presentation: answerPresentation, designTokens: designTokens),
            required: input.flatMap { SurveyParse.bool($0["required"]) } ?? (kind == .question),
            hidden: false,
            showMedia: false,
            media: .empty,
            showTag: false,
            showAnswerMedia: false,
            showAnswerDescriptions: false,
            shuffle: false,
            allowOther: false,
            answerLayout: answerLayout(answerPresentation),
            backgroundColor: "",
            numberMin: input.flatMap { SurveyParse.double($0["minimum"]) },
            numberMax: input.flatMap { SurveyParse.double($0["maximum"]) },
            showWhen: nil
        )
    }

    private static func inputStyle(
        _ input: [String: JSONValue]?,
        designTokens: DesignTokenCatalog
    ) -> ElementStyle? {
        guard let style = input.flatMap({ SurveyParse.object($0["style"]) }) else { return nil }
        return ElementStyle(
            size: max(0, SurveyParse.double(style["fontSize"]) ?? 0),
            weight: fontWeight(style["fontWeight"], default: 400),
            align: .left,
            colorHex: colorHex(style["textColor"], designTokens: designTokens, fallback: "#FF18181B")
        )
    }

    private static func npsStyle(
        _ input: [String: JSONValue]?,
        presentation: [String: JSONValue]?,
        designTokens: DesignTokenCatalog
    ) -> NpsStyle? {
        guard let input else { return nil }
        let type = normalise(SurveyParse.string(input["type"])) ?? ""
        guard type.contains("nps") else { return nil }
        let style = SurveyParse.object(presentation?["style"]) ?? [:]
        let cornerRadius = SurveyParse.double(style["cornerRadius"]) ?? 8
        let borderWidth = SurveyParse.double(style["borderWidth"]) ?? 1
        return NpsStyle(
            shape: "square",
            borderRadius: cornerRadius,
            borderWidth: borderWidth,
            borderColor: colorHex(style["borderColor"], designTokens: designTokens, fallback: "#FFE4E6EB"),
            backgroundColor: colorHex(style["unselectedFill"], designTokens: designTokens, fallback: "#FFF4F5F8"),
            selectedTile: NpsTileStyle(
                shape: "square",
                borderRadius: cornerRadius,
                borderWidth: borderWidth,
                borderColor: colorHex(
                    style["selectedBorderColor"],
                    designTokens: designTokens,
                    fallback: "#FF4945FF"
                ),
                backgroundColor: colorHex(style["selectedFill"], designTokens: designTokens, fallback: "#FFFFFFFF")
            ),
            textStyle: inputStyle(presentation, designTokens: designTokens) ?? ElementStyle(),
            scaleColors: NpsStyle.defaultScaleColors,
            tierEmojis: NpsStyle.defaultTierEmojis,
            selectedBgColor: colorHex(style["selectedFill"], designTokens: designTokens, fallback: "#FFFFFFFF"),
            faces: [],
            showFaceLabels: true
        )
    }

    private static func sceneTitle(_ scene: [String: JSONValue]) -> String {
        let promptId = SurveyParse.object(scene["roles"]).flatMap { SurveyParse.nonBlank($0["prompt"]) }
        return canvasTitle(
            scene,
            preferredChildId: promptId,
            fallback: SurveyParse.string(scene["title"]) ?? "Question"
        )
    }

    private static func canvasTitle(
        _ json: [String: JSONValue],
        preferredChildId: String? = nil,
        fallback: String
    ) -> String {
        let children = SurveyParse.object(json["canvas"]).flatMap { SurveyParse.array($0["children"]) } ?? []
        for value in children {
            guard let child = SurveyParse.object(value) else { continue }
            if let preferredChildId, SurveyParse.string(child["id"]) != preferredChildId { continue }
            let spans = SurveyParse.object(child["widget"])
                .flatMap { SurveyParse.object($0["props"]) }
                .flatMap { SurveyParse.array($0["spans"]) }
            let text = plainText(spans)
            if !text.isEmpty { return text }
        }
        return fallback
    }

    private static func plainText(_ spans: [JSONValue]?) -> String {
        (spans ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap { SurveyParse.string($0["text"]) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func answerLayout(_ input: [String: JSONValue]?) -> AnswerLayout {
        switch input.flatMap({ SurveyParse.object($0["style"]) }).flatMap({ SurveyParse.string($0["layout"]) }) {
        case "row": return .row
        case "grid": return .grid
        default: return .column
        }
    }

    private static func answerPresentation(_ scene: [String: JSONValue]) -> [String: JSONValue]? {
        let answerId = SurveyParse.object(scene["roles"]).flatMap { SurveyParse.nonBlank($0["answerInput"]) }
        let children = SurveyParse.object(scene["canvas"]).flatMap { SurveyParse.array($0["children"]) } ?? []
        for value in children {
            guard let child = SurveyParse.object(value) else { continue }
            if let answerId, SurveyParse.string(child["id"]) != answerId { continue }
            let element = SurveyParse.object(child["element"])
            guard SurveyParse.string(element?["type"]) == "canvasSurvey.answerInput" else { continue }
            return SurveyParse.object(element?["props"])
        }
        return nil
    }

    private static func nodeBranching(_ node: [String: JSONValue]) -> NodeBranching {
        let rules = (SurveyParse.array(node["rules"]) ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap(branchRule)
        return NodeBranching(
            type: rules.isEmpty ? .linear : .byCondition,
            rules: rules,
            parentNodeId: nil,
            defaultTarget: target(SurveyParse.object(node["fallback"]))
        )
    }

    private static func branchRule(_ json: [String: JSONValue]) -> BranchRule? {
        guard let id = SurveyParse.nonBlank(json["id"]) else { return nil }
        let conditions = (SurveyParse.array(json["conditions"]) ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap(condition)
        guard !conditions.isEmpty else { return nil }
        return BranchRule(
            id: id,
            whenExpr: ConditionExpr(
                operator: SurveyParse.boolOp(SurveyParse.string(json["conditionOperator"]), default: .and),
                groups: [ConditionGroup(operator: .and, conditions: conditions)]
            ),
            target: target(SurveyParse.object(json["target"]))
        )
    }

    private static func condition(_ json: [String: JSONValue]) -> Condition? {
        let op: ConditionOperator?
        let rawOperator = SurveyParse.string(json["operator"])
        switch rawOperator?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "answered": op = .isAnswered
        default: op = SurveyParse.conditionOperator(rawOperator)
        }
        guard let op else { return nil }
        return Condition(
            nodeId: SurveyParse.nonBlank(json["sourceNodeId"]),
            operator: op,
            values: conditionValues(json["value"])
        )
    }

    private static func conditionValues(_ value: JSONValue?) -> [String] {
        if let values = SurveyParse.array(value) {
            return values.compactMap { SurveyParse.nonBlank($0) }
        }
        return SurveyParse.nonBlank(value).map { [$0] } ?? []
    }

    private static func target(_ json: [String: JSONValue]?) -> BranchTarget {
        guard let json else { return .next }
        switch SurveyParse.string(json["kind"]) {
        case "node":
            return BranchTarget(kind: .node, nodeId: SurveyParse.nonBlank(json["nodeId"]), url: "")
        case "redirect":
            return BranchTarget(kind: .url, nodeId: nil, url: SurveyParse.string(json["url"]) ?? "")
        case "end":
            return .end
        default:
            return .next
        }
    }

    private static func settings(_ json: [String: JSONValue]) -> SurveySettings {
        let behavior = SurveyParse.object(json["behavior"]) ?? [:]
        return SurveySettings(
            pagination: PaginationSettings(
                numberOfPages: SurveyParse.bool(behavior["showPageCount"]) ?? true,
                progressbar: SurveyParse.bool(behavior["showProgress"]) ?? true,
                onlyShowOnQuestionBlock: SurveyParse.bool(behavior["countQuestionsOnly"]) ?? true,
                backButton: true,
                paginationStyle: .continuous,
                progressIndicatorStyle: .default
            ),
            autoAdvance: SurveyParse.bool(behavior["autoAdvance"]) ?? false,
            chooseButton: SurveyParse.bool(behavior["showPrimaryNavigation"]) ?? true,
            cta: .default,
            timer: SurveyTimerSettings(
                enabled: SurveyParse.bool(behavior["timerEnabled"]) ?? false,
                pauseOnNonTimerBlock: SurveyParse.bool(behavior["pauseTimerOnContent"]) ?? true,
                timeLimitSeconds: max(0, SurveyParse.int(behavior["timerDurationSeconds"]) ?? 0),
                warningAtSeconds: max(0, SurveyParse.int(behavior["timerWarningSeconds"]) ?? 0),
                autoPauseBetweenBlocks: false
            ),
            display: display(json)
        )
    }

    private static func display(_ json: [String: JSONValue]) -> SurveyDisplay {
        let display = SurveyParse.object(json["display"]) ?? [:]
        let cornerRadius = SurveyParse.int(display["cornerRadius"]) ?? 20
        let backdropDismissible = SurveyParse.bool(display["backdropDismissible"]) ?? true
        return SurveyDisplay(
            type: SurveyParse.displayType(SurveyParse.string(display["type"])),
            dialog: DialogProps(
                width: .medium,
                customWidth: 0,
                cornerRadius: cornerRadius,
                backdropOpacity: 0.4,
                backdropDismissible: backdropDismissible,
                showCloseButton: SurveyParse.bool(display["showCloseButton"]) ?? true
            ),
            bottomSheet: BottomSheetProps(
                heightMode: .wrap,
                customHeight: 0,
                cornerRadius: cornerRadius,
                showHandle: SurveyParse.bool(display["showHandle"]) ?? true,
                draggable: SurveyParse.bool(display["dragDismissible"]) ?? true,
                backdropDismissible: backdropDismissible
            )
        )
    }

    private static func designWidth(_ json: [String: JSONValue]) -> CGFloat {
        let display = SurveyParse.object(json["display"]) ?? [:]
        let sharedCanvas = CanvasSurveyDocumentParser.documentCanvas(SurveyParse.object(json["sharedUi"]))
        let width = SurveyParse.double(display["designWidth"])
            ?? SurveyParse.double(json["designWidth"])
            ?? sharedCanvas.flatMap { SurveyParse.double($0["canvasWidth"]) }
            ?? 360
        return CGFloat(width > 0 ? width : 360)
    }

    private static func sceneDocuments(
        _ scenes: [JSONValue],
        root: [String: JSONValue],
        designTokens: DesignTokenCatalog,
        fallbackDesignWidth: CGFloat,
        rootSceneId: String?,
        canNavigateBackFromRoot: Bool
    ) -> [String: CanvasSurveySceneDocument] {
        let documentParser = CanvasSurveyDocumentParser(designTokens: designTokens)
        let overlay = CanvasSurveySharedUiOverlay()
        let sharedCanvas = documentParser.parse(
            SurveyParse.object(root["sharedUi"]),
            fallbackDesignWidth: fallbackDesignWidth
        )
        var documents: [String: CanvasSurveySceneDocument] = [:]
        for value in scenes {
            guard let scene = SurveyParse.object(value),
                  let id = SurveyParse.nonBlank(scene["id"]) else { continue }
            let canvas = documentParser.parse(
                SurveyParse.object(scene["canvas"]),
                fallbackDesignWidth: fallbackDesignWidth
            )
            let kind = canvasSceneKind(sceneKind(SurveyParse.string(scene["kind"]) ?? "question"))
            let composed = overlay.apply(
                overrideDocument: SurveyParse.object(scene["sharedUi"]),
                master: sharedCanvas,
                body: canvas,
                fallbackDesignWidth: fallbackDesignWidth,
                isWelcome: false,
                sceneKind: kind,
                isRootScene: id == rootSceneId,
                canNavigateBackFromRoot: canNavigateBackFromRoot
            )
            documents[id] = CanvasSurveySceneDocument(
                kind: kind,
                canvas: composed.canvas,
                sharedUi: composed.sharedUi,
                canvasHosts: composed.canvasHosts,
                sharedUiHosts: composed.sharedUiHosts
            )
        }
        return documents
    }

    private static func welcomeDocument(
        _ json: [String: JSONValue],
        designTokens: DesignTokenCatalog
    ) -> CanvasSurveyDocument? {
        guard let welcome = SurveyParse.object(json["welcome"]),
              SurveyParse.bool(welcome["enabled"]) ?? false else { return nil }
        let fallbackDesignWidth = designWidth(json)
        let documentParser = CanvasSurveyDocumentParser(designTokens: designTokens)
        let sharedCanvas = documentParser.parse(
            SurveyParse.object(json["sharedUi"]),
            fallbackDesignWidth: fallbackDesignWidth
        )
        let canvas = documentParser.parse(
            SurveyParse.object(welcome["canvas"]),
            fallbackDesignWidth: fallbackDesignWidth
        )
        return CanvasSurveySharedUiOverlay().apply(
            overrideDocument: SurveyParse.object(welcome["sharedUi"]),
            master: sharedCanvas,
            body: canvas,
            fallbackDesignWidth: fallbackDesignWidth,
            isWelcome: true,
            sceneKind: nil,
            isRootScene: false,
            canNavigateBackFromRoot: false
        )
    }

    private static func sceneKind(_ value: String?) -> SceneKind {
        switch normalise(value) {
        case "question": return .question
        case "result": return .result
        default: return .content
        }
    }

    private static func canvasSceneKind(_ kind: SceneKind) -> CanvasSurveySceneKind {
        switch kind {
        case .question: return .question
        case .content: return .content
        case .result: return .result
        }
    }

    private static func colorHex(
        _ value: JSONValue?,
        designTokens: DesignTokenCatalog,
        fallback: String
    ) -> String {
        (try? designTokens.resolveColor(jsonAny(value)))?.lightHex
            ?? canonicalCampaignColorHex(unwrapLiteral(jsonAny(value)))
            ?? fallback
    }

    private static func fontWeight(_ value: JSONValue?, default fallback: Int) -> Int {
        optionalFontWeight(jsonAny(value)) ?? fallback
    }

    private static func optionalFontWeight(_ raw: Any?) -> Int? {
        guard let value = unwrapLiteral(raw), !(value is NSNull) else { return nil }
        if let string = value as? String, string.lowercased().hasPrefix("w") {
            return DigiaFontWeight.optional(String(string.dropFirst()))
        }
        return DigiaFontWeight.optional(value)
    }

    private static func normalise(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func jsonObject(_ json: [String: JSONValue]) -> [String: Any] {
        json.mapValues(jsonAny)
    }

    private static func jsonAny(_ value: JSONValue?) -> Any {
        guard let value else { return NSNull() }
        switch value {
        case .string(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map(jsonAny)
        case .object(let value): return jsonObject(value)
        case .null: return NSNull()
        }
    }
}
