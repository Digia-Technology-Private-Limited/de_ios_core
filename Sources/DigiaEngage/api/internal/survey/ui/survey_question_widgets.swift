import SwiftUI

/// Synthetic option id for a choice question's "Other" entry.
let OTHER_CHOICE_ID = "__other__"

// MARK: - Visual tokens (mirror dashboard tokens)

enum SurveyTokens {
    static let border = Color(red: 0xE4 / 255, green: 0xE6 / 255, blue: 0xEB / 255)
    static let borderStrong = Color(red: 0xCD / 255, green: 0xD2 / 255, blue: 0xDA / 255)
    static let surface = Color.white
    static let surfaceSunken = Color(red: 0xF4 / 255, green: 0xF5 / 255, blue: 0xF8 / 255)
    static let textPrimary = Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x24 / 255)
    static let textSecondary = Color(red: 0x55 / 255, green: 0x60 / 255, blue: 0x6E / 255)
    static let textTertiary = Color(red: 0x8A / 255, green: 0x93 / 255, blue: 0xA1 / 255)
    static let errorRed = Color(red: 0xD9 / 255, green: 0x2D / 255, blue: 0x20 / 255)
}

// MARK: - Text defaults

struct TextDefaults {
    let sizePt: CGFloat
    let weight: Font.Weight
    let color: Color
    let align: TextAlignment

    init(sizePt: CGFloat, weight: Font.Weight, color: Color, align: TextAlignment = .leading) {
        self.sizePt = sizePt
        self.weight = weight
        self.color = color
        self.align = align
    }
}

let TitleDefaults = TextDefaults(sizePt: 20, weight: .bold, color: SurveyTokens.textPrimary)
let BodyDefaults = TextDefaults(sizePt: 14, weight: .regular, color: SurveyTokens.textSecondary)
let OptionDefaults = TextDefaults(sizePt: 16, weight: .medium, color: SurveyTokens.textPrimary)

// MARK: - Fonts

/// Resolves a survey font through the SDK-wide font factory so the global
/// `DigiaConfig.fontFamily` applies to natively-rendered surveys, matching
/// campaigns and guides. When no global family is configured the factory is
/// `DefaultFontFactory`, which returns the system font — preserving the prior
/// appearance. Shape mirrors `Font.system(size:weight:)` so it is a drop-in
/// replacement at every call site.
@MainActor
func surveyFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    SDKInstance.shared.fontFactory.getDefaultFont(
        size: Double(size), weight: weight, italic: false
    )
}

extension ElementStyle {
    /// Authored pixel size, or the element default when unset (0).
    func resolveFontSize(default def: CGFloat) -> CGFloat {
        size > 0 ? CGFloat(size) : def
    }

    func resolveWeight() -> Font.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }

    func resolveAlign() -> TextAlignment {
        switch align {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    func resolveColor(accent: Color, default def: Color) -> Color {
        Color(hex: colorHex) ?? def
    }
}

struct StyledText: View {
    let text: String
    let style: ElementStyle
    let accent: Color
    let defaults: TextDefaults

    var body: some View {
        Text(text)
            .font(
                surveyFont(
                    size: style.resolveFontSize(default: defaults.sizePt),
                    weight: style.resolveWeight())
            )
            .foregroundColor(style.resolveColor(accent: accent, default: defaults.color))
            .multilineTextAlignment(style.resolveAlign())
            .frame(maxWidth: .infinity, alignment: alignment(for: style.resolveAlign()))
    }

    private func alignment(for ta: TextAlignment) -> Alignment {
        switch ta {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Dispatch

struct SurveyQuestionContent: View {
    let block: SurveyBlock
    let answer: SurveyAnswer?
    let accent: Color
    let onAnswer: (SurveyAnswer) -> Void

    var body: some View {
        resolved()
    }

    private func resolved() -> AnyView {
        switch block.type {
        case .rating:
            return AnyView(
                StarRatingQuestion(range: 5, accent: accent, answer: answer, onAnswer: onAnswer))
        case .nps:
            return AnyView(
                NpsQuestion(
                    accent: accent, style: block.npsStyle, answer: answer, onAnswer: onAnswer))
        case .npsEmoji:
            return AnyView(
                NpsFaceQuestion(
                    accent: accent, style: block.npsStyle, faceSize: 28, answer: answer,
                    onAnswer: onAnswer))
        case .npsSmiley:
            return AnyView(
                NpsFaceQuestion(
                    accent: accent, style: block.npsStyle, faceSize: 30, answer: answer,
                    onAnswer: onAnswer))
        case .reaction:
            return AnyView(
                ReactionQuestion(block: block, accent: accent, answer: answer, onAnswer: onAnswer))
        case .thisOrThat:
            return AnyView(
                ThisOrThatQuestion(block: block, accent: accent, answer: answer, onAnswer: onAnswer)
            )
        case .tierList:
            return AnyView(
                TierListQuestion(block: block, accent: accent, answer: answer, onAnswer: onAnswer))
        case .singleSelect, .multiSelect, .upvote:
            return AnyView(
                ChoiceCardQuestion(block: block, accent: accent, answer: answer, onAnswer: onAnswer)
            )
        case .shortText:
            return AnyView(
                SurveyTextQuestion(
                    accent: accent, answer: answer, onAnswer: onAnswer,
                    keyboard: .default, singleLine: true, placeholder: "Type your answer…"
                ))
        case .longText:
            return AnyView(
                SurveyTextQuestion(
                    accent: accent, answer: answer, onAnswer: onAnswer,
                    keyboard: .default, singleLine: false, placeholder: "Type your answer…",
                    minHeightPt: 100
                ))
        case .number:
            let min = block.numberMin
            let max = block.numberMax
            return AnyView(
                SurveyTextQuestion(
                    accent: accent, answer: answer, onAnswer: onAnswer,
                    keyboard: .decimalPad, singleLine: true, placeholder: "0", maxWidthPt: 200,
                    validator: { validateNumber($0, min: min, max: max) }
                ))
        case .email:
            return AnyView(
                SurveyTextQuestion(
                    accent: accent, answer: answer, onAnswer: onAnswer,
                    keyboard: .emailAddress, singleLine: true, placeholder: "you@example.com",
                    validator: validateEmail
                ))
        case .date:
            return AnyView(
                SurveyTextQuestion(
                    accent: accent, answer: answer, onAnswer: onAnswer,
                    keyboard: .numbersAndPunctuation, singleLine: true, placeholder: "YYYY-MM-DD",
                    maxWidthPt: 240, validator: validateDate
                ))
        case .welcome, .textMedia, .resultPage:
            return AnyView(EmptyView())
        }
    }
}

// MARK: - Star rating

private struct StarRatingQuestion: View {
    let range: Int
    let accent: Color
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    var body: some View {
        let selected = Int(answer?.values.first ?? "") ?? 0
        FlowLayout(spacing: 10) {
            ForEach(1...range, id: \.self) { i in
                let isOn = i <= selected
                Button {
                    onAnswer(SurveyAnswer(values: ["\(i)"]))
                } label: {
                    Image(systemName: "star.fill")
                        .font(surveyFont(size: 22))
                        .foregroundColor(isOn ? accent : SurveyTokens.textTertiary)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isOn ? accent.opacity(0.12) : SurveyTokens.surfaceSunken)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - NPS

private func npsBandColor(_ style: NpsStyle, _ score: Int) -> Color {
    let hex: String
    switch score {
    case ...6: hex = style.scaleColors.detractors
    case 7, 8: hex = style.scaleColors.passives
    default: hex = style.scaleColors.promoters
    }
    return Color(hex: hex) ?? .gray
}

private struct NpsQuestion: View {
    let accent: Color
    let style: NpsStyle?
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    /// Tile gap is fixed; the tile side is derived from the measured row width
    /// so all 11 tiles always fit without overflow.
    private static let gap: CGFloat = 5
    @State private var rowWidth: CGFloat = 0

    var body: some View {
        let style = self.style ?? .default
        let selected = Int(answer?.values.first ?? "")
        let sel = style.selectedTile
        let baseRadius: CGFloat = style.isCircle ? 999 : CGFloat(style.borderRadius)
        let selRadius: CGFloat = sel.isCircle ? 999 : CGFloat(sel.borderRadius)
        let baseBg = Color(hex: style.backgroundColor) ?? .clear
        let baseBorder = Color(hex: style.borderColor) ?? SurveyTokens.border
        let textColor = Color(hex: style.textStyle.colorHex) ?? SurveyTokens.textPrimary
        let textSize = style.textStyle.resolveFontSize(default: 13)
        let textWeight = style.textStyle.resolveWeight()
        let tile = rowWidth > 0 ? max(0, (rowWidth - Self.gap * 10) / 11) : 0
        VStack(spacing: 6) {
            HStack(spacing: Self.gap) {
                ForEach(0...10, id: \.self) { i in
                    let isOn = selected == i
                    let band = npsBandColor(style, i)
                    // Selected tile takes its own style; empty colours fall back
                    // to the sentiment band so the default look is preserved.
                    let fill = isOn ? (Color(hex: sel.backgroundColor) ?? band) : baseBg
                    let borderColor = isOn ? (Color(hex: sel.borderColor) ?? band) : baseBorder
                    let borderW = CGFloat(isOn ? sel.borderWidth : style.borderWidth)
                    let radius = isOn ? selRadius : baseRadius
                    Button {
                        onAnswer(SurveyAnswer(values: ["\(i)"]))
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: radius)
                                .fill(fill)
                                .overlay(
                                    RoundedRectangle(cornerRadius: radius)
                                        .stroke(borderColor, lineWidth: borderW)
                                )
                            Text("\(i)")
                                .font(surveyFont(size: textSize, weight: textWeight))
                                .foregroundColor(isOn ? .white : textColor)
                        }
                        .frame(width: tile, height: tile)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.width, initial: true) { _, w in
                        rowWidth = w
                    }
                }
            )
            HStack {
                Text("Not likely").font(surveyFont(size: 11)).foregroundColor(
                    SurveyTokens.textTertiary)
                Spacer()
                Text("Extremely likely").font(surveyFont(size: 11)).foregroundColor(
                    SurveyTokens.textTertiary)
            }
        }
    }
}

/// Face scale for `nps_emoji` (5 faces) / `nps_smiley` (3 faces) — rounded-square
/// tiles. The answer is the 1-based face index as a scalar string.
private struct NpsFaceQuestion: View {
    let accent: Color
    let style: NpsStyle?
    let faceSize: CGFloat
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    var body: some View {
        let style = self.style ?? .default
        let faces = style.faces
        let sel = style.selectedTile
        let baseRadius: CGFloat = style.isCircle ? 999 : CGFloat(style.borderRadius)
        let selRadius: CGFloat = sel.isCircle ? 999 : CGFloat(sel.borderRadius)
        let baseBg = Color(hex: style.backgroundColor) ?? SurveyTokens.surfaceSunken
        let baseBorder = Color(hex: style.borderColor) ?? SurveyTokens.border
        let labelColor = Color(hex: style.textStyle.colorHex) ?? SurveyTokens.textPrimary
        let labelSize = style.textStyle.resolveFontSize(default: 13)
        let labelWeight = style.textStyle.resolveWeight()
        let selected = Int(answer?.values.first ?? "")
        HStack(alignment: .top, spacing: 10) {
            ForEach(Array(faces.enumerated()), id: \.offset) { index, face in
                let value = index + 1
                let isOn = selected == value
                let fill = isOn ? (Color(hex: sel.backgroundColor) ?? accent.opacity(0.12)) : baseBg
                let borderColor = isOn ? (Color(hex: sel.borderColor) ?? accent) : baseBorder
                let borderW = CGFloat(isOn ? sel.borderWidth : style.borderWidth)
                let radius = isOn ? selRadius : baseRadius
                Button {
                    onAnswer(SurveyAnswer(values: ["\(value)"]))
                } label: {
                    VStack(spacing: 6) {
                        Text(face.emoji)
                            .font(surveyFont(size: faceSize))
                            .frame(width: 56, height: 56)
                            .background(RoundedRectangle(cornerRadius: radius).fill(fill))
                            .overlay(
                                RoundedRectangle(cornerRadius: radius).stroke(
                                    borderColor, lineWidth: borderW)
                            )
                            .scaleEffect(isOn ? 1.1 : 1.0)
                        if style.showFaceLabels && !face.label.isEmpty {
                            Text(face.label)
                                .font(surveyFont(size: labelSize, weight: labelWeight))
                                .foregroundColor(isOn ? accent : labelColor)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Reaction

private struct ReactionQuestion: View {
    let block: SurveyBlock
    let accent: Color
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    var body: some View {
        let selectedId = answer?.values.first
        FlowLayout(spacing: 10) {
            ForEach(block.options) { option in
                let isOn = selectedId == option.id
                Button {
                    onAnswer(SurveyAnswer(values: [option.id]))
                } label: {
                    Text(option.label)
                        .font(surveyFont(size: 32))
                        .frame(width: 64, height: 64)
                        .background(
                            Circle().fill(isOn ? accent.opacity(0.14) : SurveyTokens.surfaceSunken)
                        )
                        .overlay(
                            Circle().stroke(
                                isOn ? accent : SurveyTokens.border, lineWidth: isOn ? 2 : 1.5)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - This or That

private struct ThisOrThatQuestion: View {
    let block: SurveyBlock
    let accent: Color
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    private let gradients: [LinearGradient] = [
        LinearGradient(
            colors: [Color(red: 1, green: 0.6, blue: 0.4), Color(red: 1, green: 0.36, blue: 0.38)],
            startPoint: .topLeading, endPoint: .bottomTrailing),
        LinearGradient(
            colors: [
                Color(red: 0.42, green: 0.42, blue: 1), Color(red: 0.29, green: 0.27, blue: 1),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing),
    ]

    var body: some View {
        let opts = Array(block.options.prefix(2))
        let selectedId = answer?.values.first
        HStack(spacing: 12) {
            ForEach(Array(opts.enumerated()), id: \.offset) { index, option in
                let isOn = selectedId == option.id
                Button {
                    onAnswer(SurveyAnswer(values: [option.id]))
                } label: {
                    ZStack(alignment: .bottomLeading) {
                        RoundedRectangle(cornerRadius: 14).fill(gradients[index % gradients.count])
                        Text(option.label)
                            .font(surveyFont(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .padding(14)
                    }
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(isOn ? accent : .clear, lineWidth: isOn ? 3 : 0)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Tier List

private struct TierListQuestion: View {
    let block: SurveyBlock
    let accent: Color
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    @State private var placements: [String: String] = [:]
    @State private var hydrated = false

    private let tiers: [(label: String, color: Color)] = [
        ("S", Color(red: 1, green: 0.36, blue: 0.38)),
        ("A", Color(red: 1, green: 0.64, blue: 0.32)),
        ("B", Color(red: 0.36, green: 0.78, blue: 0.47)),
        ("C", Color(red: 0.31, green: 0.54, blue: 0.88)),
    ]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(tiers.enumerated()), id: \.offset) { _, t in
                HStack(spacing: 6) {
                    Text(t.label)
                        .font(surveyFont(size: 18, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 6).fill(t.color))
                    TierChips(
                        items: block.options.filter { placements[$0.id] == t.label }, onTap: cycle
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(SurveyTokens.surfaceSunken)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(SurveyTokens.border, lineWidth: 1)
                    )
                }
            }
            TierChips(
                items: block.options.filter { (placements[$0.id] ?? "-") == "-" },
                onTap: cycle,
                placeholder: "Tap a chip to assign a tier"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .overlay(
                RoundedRectangle(cornerRadius: 6).stroke(SurveyTokens.border, lineWidth: 1)
            )
        }
        .onAppear {
            guard !hydrated else { return }
            hydrated = true
            answer?.values.forEach { pair in
                let parts = pair.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { placements[parts[1]] = parts[0] }
            }
        }
    }

    private func cycle(_ optionId: String) {
        let ordered = ["-"] + tiers.map { $0.label }
        let current = placements[optionId] ?? "-"
        let next = ordered[(ordered.firstIndex(of: current).map { $0 + 1 } ?? 0) % ordered.count]
        placements[optionId] = next
        emit()
    }

    private func emit() {
        let labels = Set(tiers.map { $0.label })
        let list =
            placements
            .filter { labels.contains($0.value) }
            .map { "\($0.value):\($0.key)" }
        onAnswer(SurveyAnswer(values: list))
    }
}

private struct TierChips: View {
    let items: [SurveyOption]
    let onTap: (String) -> Void
    var placeholder: String? = nil

    var body: some View {
        if items.isEmpty {
            if let placeholder {
                Text(placeholder)
                    .font(surveyFont(size: 11))
                    .foregroundColor(SurveyTokens.textTertiary)
            }
        } else {
            FlowLayout(spacing: 6) {
                ForEach(items) { opt in
                    Button {
                        onTap(opt.id)
                    } label: {
                        Text(opt.label)
                            .font(surveyFont(size: 12))
                            .foregroundColor(SurveyTokens.textPrimary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4).fill(SurveyTokens.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4).stroke(
                                    SurveyTokens.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Choice cards (single/multi/upvote)

private struct ChoiceCardQuestion: View {
    let block: SurveyBlock
    let accent: Color
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    @State private var selected: [String: Bool] = [:]
    @State private var otherText: String = ""
    @State private var hydrated = false

    var body: some View {
        let multi = block.type.isMultiSelect
        let otherSelected = selected[OTHER_CHOICE_ID] == true
        let options =
            block.options
            + (block.allowOther
                ? [SurveyOption(id: OTHER_CHOICE_ID, label: "Other…", description: nil, media: nil)]
                : [])

        VStack(alignment: .leading, spacing: 8) {
            let card: (SurveyOption) -> ChoiceCardRow = { option in
                ChoiceCardRow(
                    option: option,
                    selected: selected[option.id] == true,
                    multi: multi,
                    accent: accent,
                    optionStyle: block.optionStyle,
                    showMedia: block.showAnswerMedia,
                    showDescription: block.showAnswerDescriptions,
                    wide: true,
                    onTap: { toggle(option.id, multi: multi) }
                )
            }
            switch block.answerLayout {
            case .row:
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(options) { card($0) }
                }
            case .grid:
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                    ],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(options) { card($0) }
                }
            case .column:
                VStack(spacing: 8) {
                    ForEach(options) { card($0) }
                }
            }

            if block.allowOther && otherSelected {
                OutlinedTextField(
                    placeholder: "Please specify…",
                    text: Binding(
                        get: { otherText },
                        set: { v in
                            otherText = v
                            emit()
                        }),
                    keyboard: .default,
                    singleLine: true,
                    minHeight: 0,
                    hasError: false
                )
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            guard !hydrated else { return }
            hydrated = true
            otherText = answer?.comment ?? ""
            answer?.values.forEach { selected[$0] = true }
        }
    }

    private func toggle(_ id: String, multi: Bool) {
        if multi {
            selected[id] = !(selected[id] ?? false)
        } else {
            for key in selected.keys { selected[key] = false }
            selected[id] = true
        }
        emit()
    }

    private func emit() {
        let ids = selected.filter { $0.value }.map { $0.key }
        let comment = (selected[OTHER_CHOICE_ID] == true) ? otherText : nil
        onAnswer(SurveyAnswer(values: ids, comment: comment))
    }
}

private struct ChoiceCardRow: View {
    let option: SurveyOption
    let selected: Bool
    let multi: Bool
    let accent: Color
    var optionStyle: ElementStyle? = nil
    let showMedia: Bool
    let showDescription: Bool
    let wide: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Group {
                        if multi {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(selected ? accent : Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(
                                            selected ? accent : SurveyTokens.borderStrong,
                                            lineWidth: 1.5)
                                )
                        } else {
                            Circle()
                                .fill(selected ? accent : Color.clear)
                                .overlay(
                                    Circle().stroke(
                                        selected ? accent : SurveyTokens.borderStrong,
                                        lineWidth: 1.5)
                                )
                        }
                    }
                    .frame(width: 20, height: 20)

                    if showMedia, let media = option.media, media.hasUrl {
                        AsyncImage(url: URL(string: media.url)) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            SurveyTokens.surfaceSunken
                        }
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    StyledText(
                        text: option.label,
                        style: optionStyle ?? ElementStyle(),
                        accent: accent,
                        defaults: OptionDefaults
                    )
                }
                if showDescription, let desc = option.description, !desc.isEmpty {
                    Text(desc)
                        .font(surveyFont(size: 12))
                        .foregroundColor(SurveyTokens.textSecondary)
                        .padding(.leading, 32)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: wide ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? accent.opacity(0.08) : SurveyTokens.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? accent : SurveyTokens.border, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Text inputs

/// Mirrors Material's `OutlinedTextField`: thin rounded outline, 16pt horizontal /
/// ~14pt vertical inner padding, error-state border, multi-line variant that
/// grows from `minHeight` upward.
struct OutlinedTextField: View {
    let placeholder: String
    @Binding var text: String
    let keyboard: UIKeyboardType
    let singleLine: Bool
    let minHeight: CGFloat
    let hasError: Bool

    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if singleLine {
                TextField(placeholder, text: $text)
                    .keyboardType(keyboard)
                    .focused($focused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
            } else {
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundColor(SurveyTokens.textTertiary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $text)
                        .focused($focused)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .frame(minHeight: minHeight, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .stroke(borderColor, lineWidth: focused ? 2 : 1)
        )
    }

    private var borderColor: Color {
        if hasError { return SurveyTokens.errorRed }
        if focused { return SurveyTokens.borderStrong }
        return SurveyTokens.border
    }
}

struct InputValidation {
    let error: String?
}

struct SurveyTextQuestion: View {
    let accent: Color
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void
    let keyboard: UIKeyboardType
    let singleLine: Bool
    var placeholder: String = ""
    var minHeightPt: CGFloat = 0
    var maxWidthPt: CGFloat = 0
    var validator: (String) -> InputValidation = { _ in InputValidation(error: nil) }

    @State private var text: String = ""
    @State private var liveError: String? = nil
    @State private var hydrated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OutlinedTextField(
                placeholder: placeholder,
                text: Binding(get: { text }, set: { handle($0) }),
                keyboard: keyboard,
                singleLine: singleLine,
                minHeight: minHeightPt > 0 ? minHeightPt : (singleLine ? 0 : 100),
                hasError: liveError != nil
            )
            .frame(maxWidth: maxWidthPt > 0 ? maxWidthPt : .infinity, alignment: .leading)

            if let msg = liveError {
                Text(msg).font(surveyFont(size: 12)).foregroundColor(SurveyTokens.errorRed)
            }
        }
        .onAppear {
            guard !hydrated else { return }
            hydrated = true
            text = answer?.values.first ?? ""
        }
    }

    private func handle(_ newText: String) {
        text = newText
        let trimmed = newText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            liveError = nil
            onAnswer(SurveyAnswer(values: []))
            return
        }
        let validation = validator(trimmed)
        liveError = validation.error
        if validation.error == nil {
            onAnswer(SurveyAnswer(values: [trimmed]))
        } else {
            // Reject invalid input: clear the answer so canAdvance stays false.
            onAnswer(SurveyAnswer(values: []))
        }
    }
}

// MARK: - Validators

private let EMAIL_REGEX = try? NSRegularExpression(
    pattern: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
)
private let DATE_REGEX = try? NSRegularExpression(
    pattern: #"^(\d{4})-(\d{2})-(\d{2}) ?$"#
)

private func validateNumber(_ input: String, min: Double?, max: Double?) -> InputValidation {
    guard let n = Double(input) else { return InputValidation(error: "Enter a valid number") }
    if let min, n < min { return InputValidation(error: "Must be at least \(formatBound(min))") }
    if let max, n > max { return InputValidation(error: "Must be at most \(formatBound(max))") }
    if let min, let max, min > max { return InputValidation(error: "Invalid range configured") }
    return InputValidation(error: nil)
}

private func formatBound(_ v: Double) -> String {
    v == Double(Int(v)) ? String(Int(v)) : String(v)
}

private func validateEmail(_ input: String) -> InputValidation {
    let range = NSRange(input.startIndex..., in: input)
    if EMAIL_REGEX?.firstMatch(in: input, range: range) != nil {
        return InputValidation(error: nil)
    }
    return InputValidation(error: "Enter a valid email address")
}

private func validateDate(_ input: String) -> InputValidation {
    let range = NSRange(input.startIndex..., in: input)
    guard let match = DATE_REGEX?.firstMatch(in: input, range: range),
        match.numberOfRanges == 4,
        let yr = Range(match.range(at: 1), in: input),
        let mr = Range(match.range(at: 2), in: input),
        let dr = Range(match.range(at: 3), in: input),
        let year = Int(input[yr]),
        let month = Int(input[mr]),
        let day = Int(input[dr])
    else {
        return InputValidation(error: "Use format YYYY-MM-DD")
    }
    if !(1...12).contains(month) { return InputValidation(error: "Month must be 01–12") }
    let maxDay: Int
    switch month {
    case 1, 3, 5, 7, 8, 10, 12: maxDay = 31
    case 4, 6, 9, 11: maxDay = 30
    case 2: maxDay = ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) ? 29 : 28
    default: maxDay = 31
    }
    if !(1...maxDay).contains(day) { return InputValidation(error: "Day must be 01–\(maxDay)") }
    return InputValidation(error: nil)
}

// MARK: - FlowLayout

/// Minimal flow layout that wraps children onto new lines when out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var maxRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth && rowWidth > 0 {
                totalHeight += rowHeight + spacing
                maxRowWidth = max(maxRowWidth, rowWidth - spacing)
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight
        maxRowWidth = max(maxRowWidth, rowWidth - spacing)
        return CGSize(width: maxRowWidth.isFinite ? maxRowWidth : 0, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        let maxX = bounds.maxX

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxX && x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
