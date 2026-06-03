import Foundation

// Survey schema delivered by the getCampaigns API inside a `campaign_type ==
// "survey"` campaign's `surveyConfig`. 1:1 mirror of the dashboard `Survey`
// type (see dashboard `src/types/survey.types.ts`) and of the Android SDK's
// `SurveyConfigModel.kt`.
//
// Naming convention: the wire is camelCase throughout (the dashboard persists
// `widgetConfig` verbatim and oxlint enforces camelCase). All keys read here
// MUST be camelCase.

// MARK: - Enums

enum SurveyBlockType: String {
    case singleSelect = "single_select"
    case multiSelect = "multi_select"
    case rating
    case nps
    case npsEmoji = "nps_emoji"
    case npsSmiley = "nps_smiley"
    case reaction
    case thisOrThat = "this_or_that"
    case tierList = "tier_list"
    case upvote
    case shortText = "short_text"
    case longText = "long_text"
    case number
    case email
    case date
    case welcome
    case textMedia = "text_media"
    case resultPage = "result_page"

    var isContent: Bool { self == .welcome || self == .textMedia || self == .resultPage }
    var isMultiSelect: Bool { self == .multiSelect || self == .tierList || self == .upvote }
    /// Any of the NPS skins (numeric grid + face scales).
    var isNps: Bool { self == .nps || self == .npsEmoji || self == .npsSmiley }
    var isChoice: Bool {
        switch self {
        case .singleSelect, .multiSelect, .reaction, .thisOrThat, .tierList, .upvote: return true
        default: return false
        }
    }
    var isText: Bool {
        switch self {
        case .shortText, .longText, .number, .email, .date: return true
        default: return false
        }
    }
    /// Single-pick blocks that can sensibly advance themselves once an answer
    /// lands. Multi-select / text inputs always need the explicit Next CTA.
    var isAutoAdvanceCandidate: Bool {
        switch self {
        case .singleSelect, .rating, .nps, .npsEmoji, .npsSmiley, .reaction: return true
        default: return false
        }
    }
}

enum BoolOp { case and, or }

enum ConditionOperator {
    case equals, notEquals, contains, notContains
    case includesAll, includesAny, isExactly
    case greaterThan, lessThan, isBetween
    case isAnswered, isNotAnswered
}

enum BranchingType { case linear, byCondition, byParent }
enum BranchTargetKind { case next, node, url, end }
enum MediaPosition { case top, inline, background }
enum AnswerLayout { case row, column, grid }
enum SurveyFontWeight { case regular, medium, semibold, bold }
enum SurveyTextAlign { case left, center, right }
enum SurveyDisplayType { case dialog, bottomSheet }
enum DialogWidthPreset { case small, medium, large, custom }
enum BottomSheetHeightMode { case wrap, half, full, custom }
enum PaginationStyle { case continuous, segmented }
enum CtaLayout { case inline, stacked }
// (text size is now a numeric px value on ElementStyle, not an enum)
enum CtaArrangement { case spaceBetween, spaceEvenly, center, start, end }

// MARK: - Styling primitives

struct ElementStyle: Equatable {
    /// Font size in pixels; 0 means "inherit the element default".
    var size: Double = 0
    var weight: SurveyFontWeight = .regular
    var align: SurveyTextAlign = .left
    /// Empty colorHex inherits theme default.
    var colorHex: String = ""

    static func from(_ json: [String: JSONValue]?) -> ElementStyle {
        guard let json else { return ElementStyle() }
        return ElementStyle(
            size: SurveyParse.double(json["size"]) ?? 0,
            weight: SurveyParse.fontWeight(SurveyParse.string(json["weight"])),
            align: SurveyParse.textAlign(SurveyParse.string(json["align"])),
            colorHex: SurveyParse.string(json["color"]) ?? ""
        )
    }
}

struct RichText: Equatable {
    let text: String
    let style: ElementStyle

    init(text: String, style: ElementStyle = ElementStyle()) {
        self.text = text
        self.style = style
    }

    static func from(_ json: [String: JSONValue]?) -> RichText? {
        guard let json else { return nil }
        let text = SurveyParse.string(json["text"]) ?? ""
        return RichText(text: text, style: ElementStyle.from(SurveyParse.object(json["style"])))
    }
}

// MARK: - Block content

struct BlockMedia: Equatable {
    let url: String
    let alt: String
    let position: MediaPosition

    var hasUrl: Bool { !url.isEmpty }

    static let empty = BlockMedia(url: "", alt: "", position: .top)

    static func from(_ json: [String: JSONValue]?) -> BlockMedia {
        guard let json else { return .empty }
        return BlockMedia(
            url: SurveyParse.string(json["url"]) ?? "",
            alt: SurveyParse.string(json["alt"]) ?? "",
            position: SurveyParse.mediaPosition(SurveyParse.string(json["position"]))
        )
    }
}

struct SurveyOption: Equatable, Identifiable {
    let id: String
    let label: String
    /// Optional secondary line — surfaced when the block's `showAnswerDescriptions` is on.
    let description: String?
    /// Optional thumbnail — surfaced when the block's `showAnswerMedia` is on.
    let media: BlockMedia?

    static func from(_ json: [String: JSONValue]) -> SurveyOption? {
        guard let id = SurveyParse.string(json["id"]), !id.isEmpty else { return nil }
        let label = SurveyParse.string(json["label"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? SurveyParse.string(json["value"]) ?? id
        let media = SurveyParse.object(json["media"]).map(BlockMedia.from).flatMap { $0.hasUrl ? $0 : nil }
        let description = SurveyParse.string(json["description"]).flatMap { $0.isEmpty ? nil : $0 }
        return SurveyOption(id: id, label: label, description: description, media: media)
    }
}

// MARK: - NPS styling

/// One value per sentiment band: detractors 0–6, passives 7–8, promoters 9–10.
struct NpsSentiment: Equatable {
    let detractors: String
    let passives: String
    let promoters: String

    static func from(_ json: [String: JSONValue]?, defaults: NpsSentiment) -> NpsSentiment {
        guard let json else { return defaults }
        func pick(_ key: String, _ def: String) -> String {
            SurveyParse.string(json[key]).flatMap { $0.isEmpty ? nil : $0 } ?? def
        }
        return NpsSentiment(
            detractors: pick("detractors", defaults.detractors),
            passives: pick("passives", defaults.passives),
            promoters: pick("promoters", defaults.promoters)
        )
    }
}

/// One editable point on a face scale (`nps_emoji` / `nps_smiley`).
struct NpsFace: Equatable {
    let emoji: String
    let label: String

    static func from(_ json: [String: JSONValue]) -> NpsFace? {
        let emoji = SurveyParse.string(json["emoji"]) ?? ""
        guard !emoji.isEmpty else { return nil }
        return NpsFace(emoji: emoji, label: SurveyParse.string(json["label"]) ?? "")
    }
}

/// Tile appearance for the numeric grid (also used for the selected tile).
struct NpsTileStyle: Equatable {
    /// "square" | "circle"; circle rounds the tile fully.
    let shape: String
    let borderRadius: Double
    let borderWidth: Double
    let borderColor: String
    let backgroundColor: String

    static let `default` = NpsTileStyle(
        shape: "square", borderRadius: 8, borderWidth: 1, borderColor: "", backgroundColor: ""
    )

    var isCircle: Bool { shape == "circle" }

    static func from(_ json: [String: JSONValue]?) -> NpsTileStyle {
        guard let json else { return .default }
        return NpsTileStyle(
            shape: SurveyParse.string(json["shape"]) ?? "square",
            borderRadius: SurveyParse.double(json["borderRadius"]) ?? 8,
            borderWidth: SurveyParse.double(json["borderWidth"]) ?? 1,
            borderColor: SurveyParse.string(json["borderColor"]) ?? "",
            backgroundColor: SurveyParse.string(json["backgroundColor"]) ?? ""
        )
    }
}

/// Presentation styling shared across the NPS variants. Empty-string colours
/// inherit the theme / sentiment-band default.
struct NpsStyle: Equatable {
    // Numeric grid tiles (`nps`)
    let shape: String
    let borderRadius: Double
    let borderWidth: Double
    let borderColor: String
    let backgroundColor: String
    let selectedTile: NpsTileStyle
    // Scale text (numbers / face captions)
    let textStyle: ElementStyle
    // Sentiment palette
    let scaleColors: NpsSentiment
    let tierEmojis: NpsSentiment
    let selectedBgColor: String
    // Face scales (`nps_emoji` / `nps_smiley`)
    let faces: [NpsFace]
    let showFaceLabels: Bool

    var isCircle: Bool { shape == "circle" }

    static let defaultScaleColors = NpsSentiment(
        detractors: "#F2675A", passives: "#D7C928", promoters: "#55B82E"
    )
    static let defaultTierEmojis = NpsSentiment(detractors: "😡", passives: "😐", promoters: "😍")

    // Defaults mirror the dashboard `defaultNpsStyle`.
    static let `default` = NpsStyle(
        shape: "square", borderRadius: 8, borderWidth: 1,
        borderColor: "#E4E6EB", backgroundColor: "#F4F5F8",
        selectedTile: .default,
        textStyle: ElementStyle(size: 13, weight: .semibold, align: .center, colorHex: "#1A1D24"),
        scaleColors: defaultScaleColors, tierEmojis: defaultTierEmojis,
        selectedBgColor: "#FFFFFF", faces: [], showFaceLabels: true
    )

    static func from(_ json: [String: JSONValue]?) -> NpsStyle? {
        guard let json else { return nil }
        func hex(_ key: String, _ def: String) -> String {
            SurveyParse.string(json[key]).flatMap { $0.isEmpty ? nil : $0 } ?? def
        }
        let faces = (SurveyParse.array(json["faces"]) ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap(NpsFace.from)
        return NpsStyle(
            shape: SurveyParse.string(json["shape"]) ?? "square",
            borderRadius: SurveyParse.double(json["borderRadius"]) ?? 8,
            borderWidth: SurveyParse.double(json["borderWidth"]) ?? 1,
            borderColor: hex("borderColor", "#E4E6EB"),
            backgroundColor: hex("backgroundColor", "#F4F5F8"),
            selectedTile: NpsTileStyle.from(SurveyParse.object(json["selectedTile"])),
            textStyle: ElementStyle.from(SurveyParse.object(json["textStyle"])),
            scaleColors: NpsSentiment.from(SurveyParse.object(json["scaleColors"]), defaults: defaultScaleColors),
            tierEmojis: NpsSentiment.from(SurveyParse.object(json["tierEmojis"]), defaults: defaultTierEmojis),
            selectedBgColor: hex("selectedBgColor", "#FFFFFF"),
            faces: faces,
            showFaceLabels: SurveyParse.bool(json["showFaceLabels"]) ?? true
        )
    }
}

// MARK: - Branching

/// A single test against one node's answer.
struct Condition: Equatable {
    /// nil = tests the owning node's own answer; non-nil = earlier node's answer.
    let nodeId: String?
    let `operator`: ConditionOperator
    let values: [String]

    static func from(_ json: [String: JSONValue]) -> Condition? {
        guard let op = SurveyParse.conditionOperator(SurveyParse.string(json["operator"])) else { return nil }
        return Condition(
            nodeId: SurveyParse.nonBlank(json["nodeId"]),
            operator: op,
            values: SurveyParse.stringArray(json["values"])
        )
    }
}

struct ConditionGroup: Equatable {
    let `operator`: BoolOp
    let conditions: [Condition]

    static func from(_ json: [String: JSONValue]?) -> ConditionGroup? {
        guard let json, let arr = SurveyParse.array(json["conditions"]) else { return nil }
        let conditions = arr.compactMap { SurveyParse.object($0) }.compactMap(Condition.from)
        guard !conditions.isEmpty else { return nil }
        return ConditionGroup(
            operator: SurveyParse.boolOp(SurveyParse.string(json["operator"]), default: .and),
            conditions: conditions
        )
    }
}

struct ConditionExpr: Equatable {
    let `operator`: BoolOp
    let groups: [ConditionGroup]

    static func from(_ json: [String: JSONValue]?) -> ConditionExpr? {
        guard let json, let arr = SurveyParse.array(json["groups"]) else { return nil }
        let groups = arr.compactMap { SurveyParse.object($0) }.compactMap(ConditionGroup.from)
        guard !groups.isEmpty else { return nil }
        return ConditionExpr(
            operator: SurveyParse.boolOp(SurveyParse.string(json["operator"]), default: .and),
            groups: groups
        )
    }
}

struct BranchTarget: Equatable {
    let kind: BranchTargetKind
    let nodeId: String?
    let url: String

    static let next = BranchTarget(kind: .next, nodeId: nil, url: "")
    static let end = BranchTarget(kind: .end, nodeId: nil, url: "")

    static func from(_ json: [String: JSONValue]?) -> BranchTarget {
        guard let json else { return .next }
        return BranchTarget(
            kind: SurveyParse.targetKind(SurveyParse.string(json["kind"])),
            nodeId: SurveyParse.nonBlank(json["nodeId"]),
            url: SurveyParse.string(json["url"]) ?? ""
        )
    }
}

struct BranchRule: Equatable {
    let id: String
    let whenExpr: ConditionExpr
    let target: BranchTarget

    static func from(_ json: [String: JSONValue]) -> BranchRule? {
        guard let id = SurveyParse.string(json["id"]), !id.isEmpty,
              let whenExpr = ConditionExpr.from(SurveyParse.object(json["when"])) else { return nil }
        return BranchRule(id: id, whenExpr: whenExpr, target: BranchTarget.from(SurveyParse.object(json["target"])))
    }
}

struct NodeBranching: Equatable {
    let type: BranchingType
    let rules: [BranchRule]
    /// Used only for `.byParent`.
    let parentNodeId: String?
    let defaultTarget: BranchTarget

    static let linearNext = NodeBranching(type: .linear, rules: [], parentNodeId: nil, defaultTarget: .next)

    static func from(_ json: [String: JSONValue]?) -> NodeBranching {
        guard let json else { return .linearNext }
        let rules = (SurveyParse.array(json["rules"]) ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap(BranchRule.from)
        return NodeBranching(
            type: SurveyParse.branchingType(SurveyParse.string(json["type"])),
            rules: rules,
            parentNodeId: SurveyParse.nonBlank(json["parentNodeId"]),
            defaultTarget: BranchTarget.from(SurveyParse.object(json["defaultTarget"]))
        )
    }
}

// MARK: - Block

struct SurveyBlock: Equatable {
    let id: String
    let type: SurveyBlockType
    let title: RichText
    let body: RichText?
    let options: [SurveyOption]
    /// Shared text style applied to every answer option (select-style blocks).
    let optionStyle: ElementStyle?
    /// Presentation styling for the NPS variants.
    let npsStyle: NpsStyle?
    let required: Bool
    /// When true the block is kept in the survey but skipped at runtime.
    let hidden: Bool
    let showMedia: Bool
    let media: BlockMedia
    /// Show the block category tag/pill above the content.
    let showTag: Bool
    let showAnswerMedia: Bool
    let showAnswerDescriptions: Bool
    let shuffle: Bool
    let allowOther: Bool
    let flexibleHeight: Bool
    let answerLayout: AnswerLayout
    /// Block surface background; an empty string inherits the survey surface.
    let backgroundColor: String
    /// NUMBER-block constraints. nil means unbounded on that side.
    let numberMin: Double?
    let numberMax: Double?
    /// Conditional visibility. When non-nil, the node is skipped if it evaluates false.
    let showWhen: ConditionExpr?

    static func from(_ json: [String: JSONValue]) -> SurveyBlock? {
        guard let id = SurveyParse.string(json["id"]), !id.isEmpty,
              let type = SurveyParse.blockType(SurveyParse.string(json["type"])) else { return nil }
        let title = RichText.from(SurveyParse.object(json["title"])) ?? RichText(text: "")
        let parsedOptions = (SurveyParse.array(json["options"]) ?? [])
            .compactMap { SurveyParse.object($0) }
            .compactMap(SurveyOption.from)
        let options = parsedOptions.isEmpty ? SurveyParse.fallbackOptions(for: type) : parsedOptions
        return SurveyBlock(
            id: id,
            type: type,
            title: title,
            body: RichText.from(SurveyParse.object(json["body"])),
            options: options,
            optionStyle: SurveyParse.object(json["optionStyle"]).map(ElementStyle.from),
            npsStyle: NpsStyle.from(SurveyParse.object(json["npsStyle"])),
            required: SurveyParse.bool(json["required"]) ?? false,
            hidden: SurveyParse.bool(json["hidden"]) ?? false,
            showMedia: SurveyParse.bool(json["showMedia"]) ?? false,
            media: BlockMedia.from(SurveyParse.object(json["media"])),
            showTag: SurveyParse.bool(json["showTag"]) ?? true,
            showAnswerMedia: SurveyParse.bool(json["showAnswerMedia"]) ?? false,
            showAnswerDescriptions: SurveyParse.bool(json["showAnswerDescriptions"]) ?? false,
            shuffle: SurveyParse.bool(json["shuffle"]) ?? false,
            allowOther: SurveyParse.bool(json["allowOther"]) ?? false,
            flexibleHeight: SurveyParse.bool(json["flexibleHeight"]) ?? false,
            answerLayout: SurveyParse.answerLayout(SurveyParse.string(json["answerLayout"])),
            backgroundColor: SurveyParse.string(json["backgroundColor"]) ?? "",
            numberMin: SurveyParse.double(json["min"]),
            numberMax: SurveyParse.double(json["max"]),
            showWhen: ConditionExpr.from(SurveyParse.object(json["showWhen"]))
        )
    }
}

// MARK: - Node

struct SurveyNode: Equatable, Identifiable {
    let id: String
    let blockId: String
    let branching: NodeBranching

    static func from(_ json: [String: JSONValue]) -> SurveyNode? {
        guard let id = SurveyParse.string(json["id"]), !id.isEmpty,
              let blockId = SurveyParse.nonBlank(json["blockId"]) else { return nil }
        return SurveyNode(id: id, blockId: blockId, branching: NodeBranching.from(SurveyParse.object(json["branching"])))
    }
}

// MARK: - Settings

struct DialogProps: Equatable {
    let width: DialogWidthPreset
    let customWidth: Int
    let cornerRadius: Int
    let backdropOpacity: Double
    let backdropDismissible: Bool
    let showCloseButton: Bool

    static let `default` = DialogProps(
        width: .medium, customWidth: 0, cornerRadius: 20,
        backdropOpacity: 0.4, backdropDismissible: true, showCloseButton: true
    )

    static func from(_ json: [String: JSONValue]?) -> DialogProps {
        guard let json else { return .default }
        let opacity = max(0, min(1, SurveyParse.double(json["backdropOpacity"]) ?? 0.4))
        return DialogProps(
            width: SurveyParse.dialogWidth(SurveyParse.string(json["width"])),
            customWidth: SurveyParse.int(json["customWidth"]) ?? 0,
            cornerRadius: SurveyParse.int(json["cornerRadius"]) ?? 20,
            backdropOpacity: opacity,
            backdropDismissible: SurveyParse.bool(json["backdropDismissible"]) ?? true,
            showCloseButton: SurveyParse.bool(json["showCloseButton"]) ?? true
        )
    }
}

struct BottomSheetProps: Equatable {
    let heightMode: BottomSheetHeightMode
    /// Viewport-height %. Used only when heightMode == .custom.
    let customHeight: Int
    let cornerRadius: Int
    let showHandle: Bool
    let draggable: Bool
    let backdropDismissible: Bool

    static let `default` = BottomSheetProps(
        heightMode: .wrap, customHeight: 0, cornerRadius: 20,
        showHandle: true, draggable: true, backdropDismissible: true
    )

    static func from(_ json: [String: JSONValue]?) -> BottomSheetProps {
        guard let json else { return .default }
        return BottomSheetProps(
            heightMode: SurveyParse.sheetHeight(SurveyParse.string(json["heightMode"])),
            customHeight: SurveyParse.int(json["customHeight"]) ?? 0,
            cornerRadius: SurveyParse.int(json["cornerRadius"]) ?? 20,
            showHandle: SurveyParse.bool(json["showHandle"]) ?? true,
            draggable: SurveyParse.bool(json["draggable"]) ?? true,
            backdropDismissible: SurveyParse.bool(json["backdropDismissible"]) ?? true
        )
    }
}

struct SurveyDisplay: Equatable {
    let type: SurveyDisplayType
    let dialog: DialogProps
    let bottomSheet: BottomSheetProps

    var dismissible: Bool {
        switch type {
        case .dialog: return dialog.backdropDismissible
        case .bottomSheet: return bottomSheet.backdropDismissible || bottomSheet.draggable
        }
    }

    static let `default` = SurveyDisplay(type: .bottomSheet, dialog: .default, bottomSheet: .default)

    static func from(_ json: [String: JSONValue]?) -> SurveyDisplay {
        guard let json else { return .default }
        return SurveyDisplay(
            type: SurveyParse.displayType(SurveyParse.string(json["type"])),
            dialog: DialogProps.from(SurveyParse.object(json["dialog"])),
            bottomSheet: BottomSheetProps.from(SurveyParse.object(json["bottomSheet"]))
        )
    }
}

/// Visual styling for the progress indicator. Empty colours inherit defaults.
struct ProgressIndicatorStyle: Equatable {
    let activeColorHex: String
    let trackColorHex: String
    let height: Double
    let cornerRadius: Double

    static let `default` = ProgressIndicatorStyle(
        activeColorHex: "", trackColorHex: "", height: 3, cornerRadius: 2
    )

    static func from(_ json: [String: JSONValue]?) -> ProgressIndicatorStyle {
        guard let json else { return .default }
        return ProgressIndicatorStyle(
            activeColorHex: SurveyParse.string(json["activeColor"]) ?? "",
            trackColorHex: SurveyParse.string(json["trackColor"]) ?? "",
            height: max(1, SurveyParse.double(json["height"]) ?? 3),
            cornerRadius: max(0, SurveyParse.double(json["cornerRadius"]) ?? 2)
        )
    }
}

struct PaginationSettings: Equatable {
    let numberOfPages: Bool
    let progressbar: Bool
    let onlyShowOnQuestionBlock: Bool
    let backButton: Bool
    let paginationStyle: PaginationStyle
    let progressIndicatorStyle: ProgressIndicatorStyle

    static let `default` = PaginationSettings(
        numberOfPages: false, progressbar: true, onlyShowOnQuestionBlock: true,
        backButton: true, paginationStyle: .continuous, progressIndicatorStyle: .default
    )

    static func from(_ json: [String: JSONValue]?) -> PaginationSettings {
        guard let json else { return .default }
        return PaginationSettings(
            numberOfPages: SurveyParse.bool(json["numberOfPages"]) ?? false,
            progressbar: SurveyParse.bool(json["progressbar"]) ?? true,
            onlyShowOnQuestionBlock: SurveyParse.bool(json["onlyShowOnQuestionBlock"]) ?? true,
            backButton: SurveyParse.bool(json["backButton"]) ?? true,
            paginationStyle: SurveyParse.paginationStyle(SurveyParse.string(json["paginationStyle"])),
            progressIndicatorStyle: ProgressIndicatorStyle.from(SurveyParse.object(json["progressIndicatorStyle"]))
        )
    }
}

struct SurveyTimerSettings: Equatable {
    let enabled: Bool
    let pauseOnNonTimerBlock: Bool
    let timeLimitSeconds: Int
    let warningAtSeconds: Int
    let autoPauseBetweenBlocks: Bool

    static let `default` = SurveyTimerSettings(
        enabled: false, pauseOnNonTimerBlock: false,
        timeLimitSeconds: 0, warningAtSeconds: 0, autoPauseBetweenBlocks: false
    )

    static func from(_ json: [String: JSONValue]?) -> SurveyTimerSettings {
        guard let json else { return .default }
        return SurveyTimerSettings(
            enabled: SurveyParse.bool(json["timer"]) ?? false,
            pauseOnNonTimerBlock: SurveyParse.bool(json["pauseOnNonTimerBlock"]) ?? false,
            timeLimitSeconds: max(0, SurveyParse.int(json["timeLimit"]) ?? 0),
            warningAtSeconds: max(0, SurveyParse.int(json["warningAt"]) ?? 0),
            autoPauseBetweenBlocks: SurveyParse.bool(json["autoPauseBetweenBlocks"]) ?? false
        )
    }
}

/// Styling, layout, and labels for the navigation CTA buttons (Next / Back, the
/// welcome "Start", the terminal "Done"). Empty colours inherit the theme accent / white.
struct CtaSettings: Equatable {
    let layout: CtaLayout
    let arrangement: CtaArrangement
    let nextLabel: String
    let backLabel: String
    let doneLabel: String
    let startLabel: String
    let bgColorHex: String
    let textColorHex: String
    let cornerRadius: Int

    static let `default` = CtaSettings(
        layout: .stacked, arrangement: .spaceBetween,
        nextLabel: "Next", backLabel: "Back", doneLabel: "Done", startLabel: "Start",
        bgColorHex: "", textColorHex: "", cornerRadius: 8
    )

    static func from(_ json: [String: JSONValue]?) -> CtaSettings {
        guard let json else { return .default }
        func label(_ key: String, _ def: String) -> String {
            SurveyParse.string(json[key]).flatMap { $0.isEmpty ? nil : $0 } ?? def
        }
        return CtaSettings(
            layout: SurveyParse.ctaLayout(SurveyParse.string(json["layout"])),
            arrangement: SurveyParse.ctaArrangement(SurveyParse.string(json["arrangement"])),
            nextLabel: label("nextLabel", "Next"),
            backLabel: label("backLabel", "Back"),
            doneLabel: label("doneLabel", "Done"),
            startLabel: label("startLabel", "Start"),
            bgColorHex: SurveyParse.string(json["bgColor"]) ?? "",
            textColorHex: SurveyParse.string(json["textColor"]) ?? "",
            cornerRadius: max(0, min(48, SurveyParse.int(json["cornerRadius"]) ?? 8))
        )
    }
}

struct SurveySettings: Equatable {
    let pagination: PaginationSettings
    let autoAdvance: Bool
    let chooseButton: Bool
    let cta: CtaSettings
    let timer: SurveyTimerSettings
    let display: SurveyDisplay

    static let `default` = SurveySettings(
        pagination: .default, autoAdvance: false, chooseButton: true,
        cta: .default, timer: .default, display: .default
    )

    static func from(_ json: [String: JSONValue]?) -> SurveySettings {
        guard let json else { return .default }
        return SurveySettings(
            pagination: PaginationSettings.from(SurveyParse.object(json["pagination"])),
            autoAdvance: SurveyParse.bool(json["autoAdvance"]) ?? false,
            chooseButton: SurveyParse.bool(json["chooseButton"]) ?? true,
            cta: CtaSettings.from(SurveyParse.object(json["cta"])),
            timer: SurveyTimerSettings.from(SurveyParse.object(json["surveyTimer"])),
            display: SurveyDisplay.from(SurveyParse.object(json["display"]))
        )
    }
}

// MARK: - Theme

struct SurveyTheme: Equatable {
    let accentHex: String
    let backgroundHex: String

    static let `default` = SurveyTheme(accentHex: "#2D6CDF", backgroundHex: "#FFFFFF")

    static func from(_ json: [String: JSONValue]?) -> SurveyTheme {
        guard let json else { return .default }
        let accent = SurveyParse.string(json["accentColor"]).flatMap { $0.isEmpty ? nil : $0 } ?? "#2D6CDF"
        let background = SurveyParse.string(json["backgroundColor"]).flatMap { $0.isEmpty ? nil : $0 } ?? "#FFFFFF"
        return SurveyTheme(accentHex: accent, backgroundHex: background)
    }
}

// MARK: - Top-level model

struct SurveyConfigModel: Equatable {
    let id: String
    let name: String?
    let blocks: [SurveyBlock]
    let nodes: [SurveyNode]
    let rootNodeId: String?
    let settings: SurveySettings
    let theme: SurveyTheme
    let uiTemplateId: String?
    let timeDelayMs: Int

    /// O(1) block lookup keyed by block id.
    var blocksById: [String: SurveyBlock] {
        Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func nodeById(_ id: String?) -> SurveyNode? {
        guard let id else { return nil }
        return nodes.first { $0.id == id }
    }

    func blockFor(_ node: SurveyNode) -> SurveyBlock? {
        blocks.first { $0.id == node.blockId }
    }

    func rootNode() -> SurveyNode? {
        nodeById(rootNodeId) ?? nodes.first
    }

    /// The welcome screen shown before the node flow, if present and not hidden.
    /// Welcome blocks are fixed intro chrome, not graph nodes.
    func welcomeBlock() -> SurveyBlock? {
        blocks.first { $0.type == .welcome && !$0.hidden }
    }

    static func from(_ json: [String: JSONValue], fallbackId: String) -> SurveyConfigModel? {
        guard let blocksArr = SurveyParse.array(json["blocks"]),
              let nodesArr = SurveyParse.array(json["nodes"]) else { return nil }
        let blocks = blocksArr.compactMap { SurveyParse.object($0) }.compactMap(SurveyBlock.from)
        // Welcome screens are intro chrome rendered before the flow, never graph
        // nodes. Drop any legacy welcome node so the flow starts at the first
        // real block.
        let welcomeBlockIds = Set(blocks.filter { $0.type == .welcome }.map { $0.id })
        let nodes = nodesArr.compactMap { SurveyParse.object($0) }.compactMap(SurveyNode.from)
            .filter { !welcomeBlockIds.contains($0.blockId) }
        guard !blocks.isEmpty, !nodes.isEmpty else { return nil }

        let id = SurveyParse.firstNonEmpty(
            SurveyParse.string(json["id"]),
            SurveyParse.string(json["_id"]),
            SurveyParse.string(json["templateId"]),
            fallbackId
        )
        let rootNodeIdRaw = SurveyParse.string(json["rootNodeId"]).flatMap { $0.isEmpty ? nil : $0 }
        let rootNodeId = (rootNodeIdRaw.map { id in nodes.contains { $0.id == id } } == true)
            ? rootNodeIdRaw : nodes.first?.id
        let name = SurveyParse.firstNonEmptyOptional(
            SurveyParse.string(json["name"]),
            SurveyParse.string(json["surveyName"]),
            SurveyParse.string(json["title"])
        )
        let uiTemplateId = SurveyParse.string(json["uiTemplateId"]).flatMap { $0.isEmpty ? nil : $0 }
        let timeDelayMs = max(0, min(10_000, SurveyParse.int(json["timeDelayMs"]) ?? 0))

        return SurveyConfigModel(
            id: id,
            name: name,
            blocks: blocks,
            nodes: nodes,
            rootNodeId: rootNodeId,
            settings: SurveySettings.from(SurveyParse.object(json["settings"])),
            theme: SurveyTheme.from(SurveyParse.object(json["theme"])),
            uiTemplateId: uiTemplateId,
            timeDelayMs: timeDelayMs
        )
    }
}

// MARK: - Parsing helpers

enum SurveyParse {

    static func string(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    static func int(_ value: JSONValue?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    static func double(_ value: JSONValue?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    static func bool(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        switch value {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let o) = value { return o }
        return nil
    }

    static func array(_ value: JSONValue?) -> [JSONValue]? {
        if case .array(let a) = value { return a }
        return nil
    }

    static func stringArray(_ value: JSONValue?) -> [String] {
        guard let arr = array(value) else { return [] }
        return arr.compactMap { string($0).flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// A non-blank string value, treating literal "null" as absent.
    static func nonBlank(_ value: JSONValue?) -> String? {
        guard let raw = string(value), !raw.isEmpty, raw != "null" else { return nil }
        return raw
    }

    static func firstNonEmpty(_ values: String?...) -> String {
        for v in values { if let v, !v.isEmpty { return v } }
        return ""
    }

    static func firstNonEmptyOptional(_ values: String?...) -> String? {
        for v in values { if let v, !v.isEmpty { return v } }
        return nil
    }

    static func fallbackOptions(for type: SurveyBlockType) -> [SurveyOption] {
        guard type == .reaction else { return [] }
        return ["🔥", "💪", "😅", "😴", "😖"].enumerated().map { (i, e) in
            SurveyOption(id: "reaction_\(i)", label: e, description: nil, media: nil)
        }
    }

    static func blockType(_ value: String?) -> SurveyBlockType? {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "single_select", "single_choice", "single": return .singleSelect
        case "multi_select", "multiple_select", "multiple_choice", "multi", "multiple": return .multiSelect
        case "rating", "star", "likert_scale": return .rating
        // gauge / slider variants render with the numeric grid for now.
        case "nps", "nps_gauge", "nps_slider": return .nps
        case "nps_emoji": return .npsEmoji
        case "nps_smiley": return .npsSmiley
        case "reaction", "smiley", "smiley_scale", "csat": return .reaction
        case "this_or_that": return .thisOrThat
        case "tier_list": return .tierList
        case "upvote": return .upvote
        case "short_text", "input", "single_input": return .shortText
        case "long_text", "open_text", "text": return .longText
        case "number", "numeric": return .number
        case "email": return .email
        case "date": return .date
        case "welcome": return .welcome
        case "text_media", "content": return .textMedia
        case "result_page", "thank_you", "thankyou", "completed": return .resultPage
        default: return nil
        }
    }

    static func conditionOperator(_ value: String?) -> ConditionOperator? {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "_") {
        case "equals", "is", "equal": return .equals
        case "not_equals", "is_not", "not_equal": return .notEquals
        case "contains", "answer_contains": return .contains
        case "not_contains", "answer_does_not_contain": return .notContains
        case "includes_all": return .includesAll
        case "includes_any", "any": return .includesAny
        case "is_exactly", "all": return .isExactly
        case "greater_than", "gt": return .greaterThan
        case "less_than", "lt": return .lessThan
        case "is_between", "between": return .isBetween
        case "is_answered", "known", "has_any_value", "question_is_answered": return .isAnswered
        case "is_not_answered", "not_known", "question_is_not_answered": return .isNotAnswered
        default: return nil
        }
    }

    static func boolOp(_ value: String?, default def: BoolOp) -> BoolOp {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "and": return .and
        case "or": return .or
        default: return def
        }
    }

    static func targetKind(_ value: String?) -> BranchTargetKind {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "node": return .node
        case "url": return .url
        case "end": return .end
        default: return .next
        }
    }

    static func branchingType(_ value: String?) -> BranchingType {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "by_condition": return .byCondition
        case "by_parent": return .byParent
        default: return .linear
        }
    }

    static func mediaPosition(_ value: String?) -> MediaPosition {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "inline": return .inline
        case "background": return .background
        default: return .top
        }
    }

    static func answerLayout(_ value: String?) -> AnswerLayout {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "row": return .row
        case "grid": return .grid
        default: return .column
        }
    }

    static func fontWeight(_ value: String?) -> SurveyFontWeight {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "medium": return .medium
        case "semibold", "semi_bold": return .semibold
        case "bold": return .bold
        default: return .regular
        }
    }

    static func textAlign(_ value: String?) -> SurveyTextAlign {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "center": return .center
        case "right": return .right
        default: return .left
        }
    }

    static func displayType(_ value: String?) -> SurveyDisplayType {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "dialog", "center": return .dialog
        default: return .bottomSheet
        }
    }

    static func dialogWidth(_ value: String?) -> DialogWidthPreset {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "small": return .small
        case "large": return .large
        case "custom": return .custom
        default: return .medium
        }
    }

    static func sheetHeight(_ value: String?) -> BottomSheetHeightMode {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "half": return .half
        case "full": return .full
        case "custom": return .custom
        default: return .wrap
        }
    }

    static func paginationStyle(_ value: String?) -> PaginationStyle {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "segmented": return .segmented
        default: return .continuous
        }
    }

    static func ctaLayout(_ value: String?) -> CtaLayout {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "inline", "row": return .inline
        default: return .stacked
        }
    }

    static func ctaArrangement(_ value: String?) -> CtaArrangement {
        switch value?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "space_evenly": return .spaceEvenly
        case "center": return .center
        case "start": return .start
        case "end": return .end
        default: return .spaceBetween
        }
    }
}
