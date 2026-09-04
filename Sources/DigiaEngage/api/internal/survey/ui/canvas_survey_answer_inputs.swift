import SwiftUI
import UIKit

struct CanvasSurveyAnswerInputView: View {
    let scene: CanvasSurveySceneDocument
    let host: CanvasSurveyAnswerHostElement
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    var body: some View {
        switch scene.input {
        case .choice(let input):
            CanvasSurveyChoiceInputView(input: input, host: host, answer: answer, onAnswer: onAnswer)
        case .field(let input):
            CanvasSurveyFieldInputView(input: input, host: host, answer: answer, onAnswer: onAnswer)
        case .scale(let input):
            CanvasSurveyScaleInputView(input: input, host: host, answer: answer, onAnswer: onAnswer)
        case nil:
            EmptyView()
        }
    }
}

private struct CanvasSurveyChoiceInputView: View {
    let input: CanvasSurveyChoiceInput
    let host: CanvasSurveyAnswerHostElement
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    var body: some View {
        let style = input.style.merge(hostStyle(host))
        let maximumSelections = host.maximumSelectionsOverride ?? input.maximumSelections
        let selected = Set(cappedValues(answer?.values ?? [], maximum: maximumSelections))
        let optionStyleMode = host.optionStyleModeOverride ?? input.optionStyleMode
        let sharedText = host.sharedText ?? input.sharedText
        switch style.layout {
        case .grid:
            let columnCount = max(1, style.columns)
            VStack(alignment: .leading, spacing: style.itemGap) {
                ForEach(Array(optionRows(input.options, columns: columnCount).enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: style.itemGap) {
                        ForEach(0..<columnCount, id: \.self) { column in
                            if column < row.count {
                                tile(option: row[column], selected: selected, maximumSelections: maximumSelections, style: style, optionStyleMode: optionStyleMode, sharedText: sharedText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Color.clear
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .row:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: style.itemGap) {
                    ForEach(input.options, id: \.id) { option in
                        tile(option: option, selected: selected, maximumSelections: maximumSelections, style: style, optionStyleMode: optionStyleMode, sharedText: sharedText)
                            .frame(minWidth: 96)
                    }
                }
            }
        case .list:
            VStack(spacing: style.itemGap) {
                ForEach(input.options, id: \.id) { option in
                    tile(option: option, selected: selected, maximumSelections: maximumSelections, style: style, optionStyleMode: optionStyleMode, sharedText: sharedText)
                }
            }
        }
    }

    private func tile(
        option: CanvasSurveyOption,
        selected: Set<String>,
        maximumSelections: Int?,
        style: CanvasSurveyInputStyle,
        optionStyleMode: CanvasSurveyOptionStyleMode,
        sharedText: CanvasSurveyOptionText?
    ) -> some View {
        let presented = presented(option, host: host, optionStyleMode: optionStyleMode, sharedText: sharedText)
        return ChoiceTile(
            option: presented,
            inputType: input.type,
            selected: selected.contains(option.id),
            style: style,
            onTap: {
                if input.type == .multiSelect {
                    var values = selected
                    if values.contains(option.id) {
                        values.remove(option.id)
                    } else {
                        values.insert(option.id)
                    }
                    if let maximum = maximumSelections, values.count > maximum { return }
                    onAnswer(SurveyAnswer(values: Array(values)))
                } else {
                    onAnswer(SurveyAnswer(values: [option.id]))
                }
            }
        )
    }
}

private func optionRows(_ options: [CanvasSurveyOption], columns: Int) -> [[CanvasSurveyOption]] {
    let columnCount = max(1, columns)
    return stride(from: 0, to: options.count, by: columnCount).map { start in
        Array(options[start..<min(start + columnCount, options.count)])
    }
}

private func cappedValues(_ values: [String], maximum: Int?) -> [String] {
    guard let maximum else { return values }
    return Array(values.prefix(maximum))
}

private struct ChoiceTile: View {
    let option: CanvasSurveyOption
    let inputType: CanvasSurveyInputType
    let selected: Bool
    let style: CanvasSurveyInputStyle
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let effective = style.merge(option.presentation.styleOverride)
        let text = option.presentation.text
        let isDark = CampaignCanvasTheme.shared.isDark(colorScheme)
        let foreground = text?.color.map { CampaignCanvasTheme.shared.color($0, isDark: isDark) }
            ?? CampaignCanvasTheme.shared.color(selected ? effective.selectedTextColor : effective.textColor, isDark: isDark)
        Button(action: onTap) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: inputType == .singleSelect ? 999 : 4)
                        .fill(selected ? CampaignCanvasTheme.shared.color(effective.selectedBorderColor, isDark: isDark) : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: inputType == .singleSelect ? 999 : 4)
                                .stroke(CampaignCanvasTheme.shared.color(selected ? effective.selectedBorderColor : effective.borderColor, isDark: isDark), lineWidth: 1)
                        )
                    if selected {
                        Text("\u{2713}")
                            .font(surveyFont(size: 10, weight: 700))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: 16, height: 16)
                Text(text?.text ?? option.label)
                    .font(surveyFont(size: text?.typography.fontSize ?? effective.fontSize, weight: text?.typography.fontWeight ?? effective.fontWeight))
                    .foregroundColor(foreground)
                    .lineLimit(inputType == .upvote ? 1 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if inputType == .upvote {
                    Text("\u{2191}")
                        .font(surveyFont(size: effective.fontSize, weight: effective.fontWeight))
                        .foregroundColor(foreground)
                }
            }
            .padding(effective.padding)
            .background(
                RoundedRectangle(cornerRadius: effective.cornerRadius)
                    .fill(CampaignCanvasTheme.shared.color(selected ? effective.selectedFill : effective.unselectedFill, isDark: isDark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: effective.cornerRadius)
                    .stroke(CampaignCanvasTheme.shared.color(selected ? effective.selectedBorderColor : effective.borderColor, isDark: isDark), lineWidth: effective.borderWidth)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct CanvasSurveyFieldInputView: View {
    let input: CanvasSurveyFieldInput
    let host: CanvasSurveyAnswerHostElement
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void
    @State private var value = ""
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = input.style.merge(hostStyle(host))
        let isDark = CampaignCanvasTheme.shared.isDark(colorScheme)
        let textColor = CampaignCanvasTheme.shared.color(style.textColor, isDark: isDark)
        let placeholderColor = Color(hex: "#FF9A9AA8") ?? textColor.opacity(0.55)
        let fillColor = CampaignCanvasTheme.shared.color(style.unselectedFill, isDark: isDark)
        let borderColor = CampaignCanvasTheme.shared.color(isFocused ? style.selectedBorderColor : style.borderColor, isDark: isDark)

        ZStack(alignment: input.type == .longText ? .topLeading : .leading) {
            if input.type == .longText {
                TextEditor(text: Binding(
                    get: { value },
                    set: { update($0) }
                ))
                .transparentTextEditorBackground()
                .focused($isFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.horizontal, max(0, style.padding - 5))
                .padding(.vertical, max(0, style.padding - 8))
                if value.isEmpty && !input.placeholder.isEmpty {
                    Text(input.placeholder)
                        .font(surveyFont(size: style.fontSize, weight: style.fontWeight))
                        .foregroundColor(placeholderColor)
                        .lineLimit(input.multilineRows)
                        .padding(style.padding)
                        .allowsHitTesting(false)
                }
            } else {
                TextField("", text: Binding(
                    get: { value },
                    set: { update($0) }
                ), prompt: Text(input.placeholder).foregroundColor(placeholderColor))
                .keyboardType(keyboardType)
                .focused($isFocused)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(style.padding)
            }
        }
        .font(surveyFont(size: style.fontSize, weight: style.fontWeight))
        .foregroundColor(textColor)
        .tint(CampaignCanvasTheme.shared.color(style.selectedBorderColor, isDark: isDark))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: input.type == .longText ? .topLeading : .leading)
        .background(
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .stroke(borderColor, lineWidth: style.borderWidth)
        )
        .onAppear { value = answer?.values.first ?? "" }
        .onChange(of: answer?.values.first) { value = $0 ?? "" }
    }

    private var keyboardType: UIKeyboardType {
        switch input.type {
        case .number: return .decimalPad
        case .email: return .emailAddress
        case .date: return .numbersAndPunctuation
        default: return .default
        }
    }

    private func update(_ newValue: String) {
        value = newValue
        onAnswer(SurveyAnswer(values: [newValue]))
    }
}

private extension View {
    @ViewBuilder
    func transparentTextEditorBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
                .background(Color.clear)
        } else {
            self.background(Color.clear)
        }
    }
}

private struct CanvasSurveyScaleInputView: View {
    let input: CanvasSurveyScaleInput
    let host: CanvasSurveyAnswerHostElement
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    var body: some View {
        let style = input.style.merge(hostStyle(host))
        let values = scaleValues(input)
        switch input.type {
        case .numericNps:
            NumericNpsScale(
                values: values,
                selected: answer?.values.first,
                circular: host.numericNpsVariant == .circle || input.numericNpsVariant == .circle,
                style: style,
                onTap: { onAnswer(SurveyAnswer(values: [$0])) }
            )
        case .rating:
            RatingScale(
                values: values,
                selectedNumber: answer?.values.first.flatMap(Double.init),
                style: style,
                symbolSize: host.symbolSize > 0 ? host.symbolSize : (input.symbolSize > 0 ? input.symbolSize : 40),
                onTap: { onAnswer(SurveyAnswer(values: [$0])) }
            )
        default:
            ReactionScale(
                values: values,
                selected: answer?.values.first,
                style: style,
                symbolSize: host.symbolSize > 0 ? host.symbolSize : (input.symbolSize > 0 ? input.symbolSize : 30),
                onTap: { onAnswer(SurveyAnswer(values: [$0])) }
            )
        }
    }
}

private struct NumericNpsScale: View {
    let values: [String]
    let selected: String?
    let circular: Bool
    let style: CanvasSurveyInputStyle
    let onTap: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = CampaignCanvasTheme.shared.isDark(colorScheme)
        GeometryReader { geo in
            let count = max(1, values.count)
            let totalGap = CGFloat(max(0, count - 1)) * 3
            let availableWidth = geo.size.width > 0 ? geo.size.width : 32
            let tileSize = max(0, min(32, (availableWidth - totalGap) / CGFloat(count)))
            HStack(spacing: 3) {
                ForEach(values, id: \.self) { value in
                    let isSelected = selected == value
                    Button { onTap(value) } label: {
                        Text(value)
                            .font(surveyFont(size: min(12, tileSize * 0.45), weight: 600))
                            .foregroundColor(CampaignCanvasTheme.shared.color(isSelected ? style.selectedTextColor : style.textColor, isDark: isDark))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(width: tileSize, height: tileSize)
                            .background(
                                RoundedRectangle(cornerRadius: circular ? 999 : min(max(0, style.cornerRadius), 16))
                                    .fill(CampaignCanvasTheme.shared.color(isSelected ? style.selectedFill : style.unselectedFill, isDark: isDark))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: circular ? 999 : min(max(0, style.cornerRadius), 16))
                                    .stroke(CampaignCanvasTheme.shared.color(isSelected ? style.selectedFill : style.borderColor, isDark: isDark), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(minHeight: 32)
    }
}

private struct RatingScale: View {
    let values: [String]
    let selectedNumber: Double?
    let style: CanvasSurveyInputStyle
    let symbolSize: CGFloat
    let onTap: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = CampaignCanvasTheme.shared.isDark(colorScheme)
        GeometryReader { geo in
            let resolvedSymbolSize = ratingSymbolSize(
                availableWidth: geo.size.width,
                count: values.count,
                symbolSize: symbolSize,
                itemGap: style.itemGap
            )
            let spacing = ratingSpacing(
                availableWidth: geo.size.width,
                count: values.count,
                symbolSize: resolvedSymbolSize,
                itemGap: style.itemGap
            )
            HStack(spacing: spacing) {
                ForEach(values, id: \.self) { value in
                    let number = Double(value)
                    let isSelected = selectedNumber != nil && number != nil && number! <= selectedNumber!
                    Button { onTap(value) } label: {
                        DashboardRatingStar(
                            color: CampaignCanvasTheme.shared.color(isSelected ? style.selectedFill : style.borderColor, isDark: isDark)
                        )
                        .frame(width: resolvedSymbolSize, height: resolvedSymbolSize)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: symbolSize)
    }
}

private struct DashboardRatingStar: View {
    let color: Color

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 24
            let offsetX = (canvasSize.width - 24 * scale) / 2
            let offsetY = (canvasSize.height - 24 * scale) / 2

            func x(_ value: CGFloat) -> CGFloat { offsetX + value * scale }
            func y(_ value: CGFloat) -> CGFloat { offsetY + value * scale }

            var path = Path()
            path.move(to: CGPoint(x: x(11.525), y: y(2.295)))
            path.addCurve(
                to: CGPoint(x: x(12.475), y: y(2.295)),
                control1: CGPoint(x: x(11.714), y: y(1.912)),
                control2: CGPoint(x: x(12.286), y: y(1.912))
            )
            path.addLine(to: CGPoint(x: x(14.785), y: y(6.974)))
            path.addCurve(
                to: CGPoint(x: x(16.38), y: y(8.134)),
                control1: CGPoint(x: x(15.094), y: y(7.6)),
                control2: CGPoint(x: x(15.691), y: y(8.035))
            )
            path.addLine(to: CGPoint(x: x(21.546), y: y(8.89)))
            path.addCurve(
                to: CGPoint(x: x(21.84), y: y(9.794)),
                control1: CGPoint(x: x(21.967), y: y(8.952)),
                control2: CGPoint(x: x(22.143), y: y(9.47))
            )
            path.addLine(to: CGPoint(x: x(18.104), y: y(13.432)))
            path.addCurve(
                to: CGPoint(x: x(17.493), y: y(15.31)),
                control1: CGPoint(x: x(17.604), y: y(13.919)),
                control2: CGPoint(x: x(17.376), y: y(14.621))
            )
            path.addLine(to: CGPoint(x: x(18.375), y: y(20.45)))
            path.addCurve(
                to: CGPoint(x: x(17.604), y: y(21.01)),
                control1: CGPoint(x: x(18.447), y: y(20.87)),
                control2: CGPoint(x: x(18.007), y: y(21.211))
            )
            path.addLine(to: CGPoint(x: x(12.986), y: y(18.582)))
            path.addCurve(
                to: CGPoint(x: x(11.014), y: y(18.582)),
                control1: CGPoint(x: x(12.369), y: y(18.258)),
                control2: CGPoint(x: x(11.631), y: y(18.258))
            )
            path.addLine(to: CGPoint(x: x(6.396), y: y(21.01)))
            path.addCurve(
                to: CGPoint(x: x(5.625), y: y(20.45)),
                control1: CGPoint(x: x(5.993), y: y(21.211)),
                control2: CGPoint(x: x(5.553), y: y(20.87))
            )
            path.addLine(to: CGPoint(x: x(6.507), y: y(15.311)))
            path.addCurve(
                to: CGPoint(x: x(5.896), y: y(13.432)),
                control1: CGPoint(x: x(6.624), y: y(14.621)),
                control2: CGPoint(x: x(6.396), y: y(13.919))
            )
            path.addLine(to: CGPoint(x: x(2.16), y: y(9.795)))
            path.addCurve(
                to: CGPoint(x: x(2.454), y: y(8.889)),
                control1: CGPoint(x: x(1.857), y: y(9.47)),
                control2: CGPoint(x: x(2.033), y: y(8.952))
            )
            path.addLine(to: CGPoint(x: x(7.619), y: y(8.134)))
            path.addCurve(
                to: CGPoint(x: x(9.215), y: y(6.974)),
                control1: CGPoint(x: x(8.309), y: y(8.035)),
                control2: CGPoint(x: x(8.906), y: y(7.6))
            )
            path.closeSubpath()

            context.fill(path, with: .color(color))
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round))
        }
    }
}

private func ratingSpacing(availableWidth: CGFloat, count: Int, symbolSize: CGFloat, itemGap: CGFloat) -> CGFloat {
    guard count > 1 else { return 0 }
    let compactWidth = symbolSize * CGFloat(count) + itemGap * CGFloat(count - 1)
    if availableWidth > compactWidth {
        return (availableWidth - symbolSize * CGFloat(count)) / CGFloat(count - 1)
    }
    return itemGap
}

private func ratingSymbolSize(availableWidth: CGFloat, count: Int, symbolSize: CGFloat, itemGap: CGFloat) -> CGFloat {
    guard count > 0, availableWidth > 0 else { return symbolSize }
    let availableForSymbols = availableWidth - itemGap * CGFloat(max(0, count - 1))
    guard availableForSymbols > 0 else { return symbolSize }
    return min(symbolSize, availableForSymbols / CGFloat(count))
}

private struct ReactionScale: View {
    let values: [String]
    let selected: String?
    let style: CanvasSurveyInputStyle
    let symbolSize: CGFloat
    let onTap: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let spacing = ratingSpacing(
                availableWidth: geo.size.width,
                count: values.count,
                symbolSize: symbolSize,
                itemGap: style.itemGap
            )
            HStack(spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.element) { index, value in
                    Button { onTap(value) } label: {
                        ReactionAssetIcon(index: index, size: symbolSize)
                            .opacity(selected == nil || selected == value ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(minHeight: symbolSize)
    }
}

private struct ReactionAssetIcon: View {
    let index: Int
    let size: CGFloat

    var body: some View {
        if let url = Bundle.canvasSurveyReactionAssets.canvasSurveyReactionImageURL(named: reactionAssetName(index)),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

private func reactionAssetName(_ index: Int) -> String {
    switch min(max(index, 0), 4) {
    case 0: return "de_reaction_very_sad"
    case 1: return "de_reaction_sad"
    case 2: return "de_reaction_neutral"
    case 3: return "de_reaction_smile"
    default: return "de_reaction_heart_eyes"
    }
}

private final class CanvasSurveyReactionBundleMarker {}

private extension Bundle {
    static var canvasSurveyReactionAssets: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        let frameworkBundle = Bundle(for: CanvasSurveyReactionBundleMarker.self)
        let candidates: [URL?] = [
            frameworkBundle.url(forResource: "DigiaEngage", withExtension: "bundle"),
            frameworkBundle.resourceURL?.appendingPathComponent("DigiaEngage.bundle"),
            Bundle.main.url(forResource: "DigiaEngage", withExtension: "bundle"),
            nil,
        ]
        for candidate in candidates {
            let bundle = candidate.flatMap { Bundle(url: $0) } ?? frameworkBundle
            if bundle.canvasSurveyReactionImageURL(named: "de_reaction_neutral") != nil {
                return bundle
            }
        }
        return frameworkBundle
        #endif
    }

    func canvasSurveyReactionImageURL(named name: String) -> URL? {
        url(forResource: name, withExtension: "png") ??
            url(forResource: name, withExtension: "png", subdirectory: "ReactionAssets")
    }
}

private func presented(
    _ option: CanvasSurveyOption,
    host: CanvasSurveyAnswerHostElement,
    optionStyleMode: CanvasSurveyOptionStyleMode,
    sharedText: CanvasSurveyOptionText?
) -> CanvasSurveyOption {
    if optionStyleMode == .shared {
        let presentation = host.optionPresentations[option.id] ?? option.presentation
        let text = sharedText.map { CanvasSurveyOptionText(text: option.label, typography: $0.typography, color: $0.color) }
        return CanvasSurveyOption(
            id: option.id,
            label: text?.text ?? option.label,
            presentation: CanvasSurveyOptionPresentation(
                text: text,
                styleOverride: presentation.styleOverride
            )
        )
    }
    let presentation = host.optionPresentations[option.id]
    return CanvasSurveyOption(
        id: option.id,
        label: presentation?.text?.text ?? option.label,
        presentation: CanvasSurveyOptionPresentation(
            text: presentation?.text ?? option.presentation.text,
            styleOverride: presentation?.styleOverride ?? option.presentation.styleOverride
        )
    )
}

private func hostStyle(_ host: CanvasSurveyAnswerHostElement) -> CanvasSurveyInputStyleOverride {
    CanvasSurveyInputStyleOverride(
        layout: host.presentationStyle.layout,
        columns: host.presentationStyle.columns,
        itemGap: host.presentationStyle.itemGap,
        fontSize: host.presentationStyle.fontSize,
        fontWeight: host.presentationStyle.fontWeight,
        textColor: host.presentationStyle.textColor,
        selectedTextColor: host.presentationStyle.selectedTextColor,
        selectedFill: host.presentationStyle.selectedFill,
        unselectedFill: host.presentationStyle.unselectedFill,
        selectedBorderColor: host.presentationStyle.selectedBorderColor,
        borderColor: host.presentationStyle.borderColor,
        borderWidth: host.presentationStyle.borderWidth,
        cornerRadius: host.presentationStyle.cornerRadius,
        padding: host.presentationStyle.padding
    )
}

private func scaleValues(_ input: CanvasSurveyScaleInput) -> [String] {
    let step = input.step <= 0 ? 1 : input.step
    var values: [String] = []
    var value = input.minimum
    while value <= input.maximum && values.count < 100 {
        values.append(value == Double(Int(value)) ? "\(Int(value))" : "\(value)")
        value += step
    }
    return values
}
