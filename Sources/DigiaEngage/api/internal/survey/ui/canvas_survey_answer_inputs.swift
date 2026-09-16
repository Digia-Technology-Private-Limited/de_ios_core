import SwiftUI
import UIKit

struct CanvasSurveyAnswerInputView: View {
    let scene: CanvasSurveySceneDocument
    let host: CanvasSurveyAnswerHostElement
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void
    let onValidationError: (String?) -> Void

    var body: some View {
        switch scene.input {
        case .choice(let input):
            CanvasSurveyChoiceInputView(
                input: input,
                host: host,
                answer: answer,
                onAnswer: onAnswer,
                onValidationError: onValidationError
            )
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
    let onValidationError: (String?) -> Void

    var body: some View {
        let style = input.style.merge(hostStyle(host))
        let maximumSelections = host.maximumSelectionsOverride ?? input.maximumSelections
        let selected = Set(cappedValues(answer?.values ?? [], maximum: maximumSelections))
        let optionStyleMode = host.optionStyleModeOverride ?? input.optionStyleMode
        let sharedText = host.sharedText ?? input.sharedText

        let metrics = CanvasSurveyAnswerMetrics.compute(
            input: .choice(input),
            hostHeight: host.rect.height,
            style: style
        )
        let scaleFactor = metrics.scaleFactor
        let availableHeight = metrics.availableHeight
        let validationReserve = metrics.validationErrorHeight

        VStack(spacing: 0) {
            Group {
                switch style.layout {
                case .grid:
                    let columnCount = max(1, style.columns)
                    let rows = optionRows(input.options, columns: columnCount)
                    let scaledGap = min(max(style.itemGap * scaleFactor, 2.0), 32.0)
                    VStack(alignment: .leading, spacing: scaledGap) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: scaledGap) {
                                ForEach(0..<columnCount, id: \.self) { column in
                                    if column < row.count {
                                        tile(
                                            option: row[column],
                                            selected: selected,
                                            maximumSelections: maximumSelections,
                                            style: style,
                                            optionStyleMode: optionStyleMode,
                                            sharedText: sharedText,
                                            scaleFactor: scaleFactor
                                        )
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                                    } else {
                                        Color.clear
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                            }
                            .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                case .row:
                    let scaledGap = min(max(style.itemGap * scaleFactor, 2.0), 32.0)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: scaledGap) {
                            ForEach(input.options, id: \.id) { option in
                                tile(
                                    option: option,
                                    selected: selected,
                                    maximumSelections: maximumSelections,
                                    style: style,
                                    optionStyleMode: optionStyleMode,
                                    sharedText: sharedText,
                                    scaleFactor: scaleFactor
                                )
                                .frame(minWidth: 96 * scaleFactor, maxHeight: .infinity)
                            }
                        }
                        .frame(maxHeight: .infinity)
                    }
                case .list:
                    let scaledGap = min(max(style.itemGap * scaleFactor, 2.0), 32.0)
                    VStack(spacing: scaledGap) {
                        ForEach(input.options, id: \.id) { option in
                            tile(
                                option: option,
                                selected: selected,
                                maximumSelections: maximumSelections,
                                style: style,
                                optionStyleMode: optionStyleMode,
                                sharedText: sharedText,
                                scaleFactor: scaleFactor
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: availableHeight)
            Spacer(minLength: 0)
                .frame(height: validationReserve)
        }
    }

    private func tile(
        option: CanvasSurveyOption,
        selected: Set<String>,
        maximumSelections: Int?,
        style: CanvasSurveyInputStyle,
        optionStyleMode: CanvasSurveyOptionStyleMode,
        sharedText: CanvasSurveyOptionText?,
        scaleFactor: CGFloat = 1.0
    ) -> some View {
        let presented = presented(option, host: host, optionStyleMode: optionStyleMode, sharedText: sharedText)
        return ChoiceTile(
            option: presented,
            inputType: input.type,
            selected: selected.contains(option.id),
            style: style,
            scaleFactor: scaleFactor,
            onTap: {
                if input.type == .multiSelect {
                    var values = selected
                    if values.contains(option.id) {
                        values.remove(option.id)
                    } else {
                        values.insert(option.id)
                    }
                    if let maximum = maximumSelections, values.count > maximum {
                        onValidationError(maxSelectionsMessage(maximum))
                        return
                    }
                    onValidationError(nil)
                    onAnswer(SurveyAnswer(values: Array(values)))
                } else {
                    onValidationError(nil)
                    onAnswer(SurveyAnswer(values: [option.id]))
                }
            }
        )
    }
}

private func maxSelectionsMessage(_ maximumSelections: Int) -> String {
    let optionWord = maximumSelections == 1 ? "option" : "options"
    return "Select at most \(maximumSelections) \(optionWord)"
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
    var scaleFactor: CGFloat = 1.0
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let effective = style.merge(option.presentation.styleOverride)
        let text = option.presentation.text
        let isDark = CampaignCanvasTheme.shared.isDark(colorScheme)
        let foreground = text?.color.map { CampaignCanvasTheme.shared.color($0, isDark: isDark) }
            ?? CampaignCanvasTheme.shared.color(selected ? effective.selectedTextColor : effective.textColor, isDark: isDark)

        let scaledIndicatorSize = min(max(16.0 * scaleFactor, 10.0), 48.0)
        let scaledCheckSize = min(max(10.0 * scaleFactor, 6.0), 32.0)
        let scaledGap = min(max(8.0 * scaleFactor, 4.0), 24.0)
        let scaledPadding = min(max(effective.padding * scaleFactor, 4.0), 36.0)
        let scaledRadius = min(max(effective.cornerRadius * scaleFactor, 0.0), 32.0)
        let indicatorRadius = inputType == .singleSelect ? 999.0 : min(max(4.0 * scaleFactor, 2.0), 12.0)
        let scaledBorderWidth = min(max(effective.borderWidth * scaleFactor, 0.5), 4.0)
        let baseFontSize = text?.typography.fontSize ?? effective.fontSize
        let scaledFontSize = min(max(baseFontSize * scaleFactor, 9.0), 28.0)
        let fontWeight = text?.typography.fontWeight ?? effective.fontWeight

        Button(action: onTap) {
            HStack(spacing: scaledGap) {
                ZStack {
                    RoundedRectangle(cornerRadius: indicatorRadius)
                        .fill(selected ? CampaignCanvasTheme.shared.color(effective.selectedBorderColor, isDark: isDark) : .clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: indicatorRadius)
                                .stroke(CampaignCanvasTheme.shared.color(selected ? effective.selectedBorderColor : effective.borderColor, isDark: isDark), lineWidth: scaledBorderWidth)
                        )
                    if selected {
                        Text("\u{2713}")
                            .font(surveyFont(size: scaledCheckSize, weight: 700))
                            .foregroundColor(.white)
                    }
                }
                .frame(width: scaledIndicatorSize, height: scaledIndicatorSize)
                Text(text?.text ?? option.label)
                    .font(surveyFont(size: scaledFontSize, weight: fontWeight))
                    .foregroundColor(foreground)
                    .lineLimit(inputType == .upvote ? 1 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if inputType == .upvote {
                    Text("\u{2191}")
                        .font(surveyFont(size: scaledFontSize, weight: fontWeight))
                        .foregroundColor(foreground)
                }
            }
            .padding(.horizontal, scaledPadding)
            .padding(.vertical, min(max(scaledPadding * 0.7, 4.0), 24.0))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: scaledRadius)
                    .fill(CampaignCanvasTheme.shared.color(selected ? effective.selectedFill : effective.unselectedFill, isDark: isDark))
            )
            .overlay(
                RoundedRectangle(cornerRadius: scaledRadius)
                    .stroke(CampaignCanvasTheme.shared.color(selected ? effective.selectedBorderColor : effective.borderColor, isDark: isDark), lineWidth: scaledBorderWidth)
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
        let metrics = CanvasSurveyAnswerMetrics.compute(
            input: .field(input),
            hostHeight: host.rect.height,
            style: style
        )
        let scaleFactor = metrics.scaleFactor
        let availableHeight = metrics.availableHeight
        let validationReserve = metrics.validationErrorHeight

        VStack(spacing: 0) {
            if input.type == .date {
                CanvasSurveyDateFieldInputView(
                    input: input,
                    style: style,
                    scaleFactor: scaleFactor,
                    availableHeight: availableHeight,
                    answer: answer,
                    onAnswer: onAnswer
                )
            } else {
                let isDark = CampaignCanvasTheme.shared.isDark(colorScheme)
                let textColor = CampaignCanvasTheme.shared.color(style.textColor, isDark: isDark)
                let placeholderColor = Color(hex: "#FF9A9AA8") ?? textColor.opacity(0.55)
                let fillColor = CampaignCanvasTheme.shared.color(style.unselectedFill, isDark: isDark)
                let borderColor = CampaignCanvasTheme.shared.color(isFocused ? style.selectedBorderColor : style.borderColor, isDark: isDark)

                let fieldFontSize = style.fontSize
                let fieldPadding = style.padding
                let scaledRadius = min(max(style.cornerRadius * scaleFactor, 0.0), 32.0)
                let scaledBorderWidth = min(max(style.borderWidth * scaleFactor, 0.5), 4.0)

                ZStack(alignment: input.type == .longText ? .topLeading : .center) {
                    if input.type == .longText {
                        TextEditor(text: Binding(
                            get: { value },
                            set: { update($0) }
                        ))
                        .transparentTextEditorBackground()
                        .focused($isFocused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, max(0, fieldPadding - 5))
                        .padding(.vertical, max(0, fieldPadding - 8))
                        if value.isEmpty && !input.placeholder.isEmpty {
                            Text(input.placeholder)
                                .font(surveyFont(size: fieldFontSize, weight: style.fontWeight))
                                .foregroundColor(placeholderColor)
                                .lineLimit(input.multilineRows)
                                .padding(fieldPadding)
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
                        .padding(fieldPadding)
                    }
                }
                .font(surveyFont(size: fieldFontSize, weight: style.fontWeight))
                .foregroundColor(textColor)
                .tint(CampaignCanvasTheme.shared.color(style.selectedBorderColor, isDark: isDark))
                .frame(maxWidth: .infinity)
                .frame(height: availableHeight, alignment: input.type == .longText ? .topLeading : .center)
                .background(
                    RoundedRectangle(cornerRadius: scaledRadius)
                        .fill(fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: scaledRadius)
                        .stroke(borderColor, lineWidth: scaledBorderWidth)
                )
                .onAppear { value = answer?.values.first ?? "" }
                .onChange(of: answer?.values.first) { value = $0 ?? "" }
            }
            Spacer(minLength: 0)
                .frame(height: validationReserve)
        }
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

private struct CanvasSurveyDateFieldInputView: View {
    let input: CanvasSurveyFieldInput
    let style: CanvasSurveyInputStyle
    var scaleFactor: CGFloat = 1.0
    var availableHeight: CGFloat = 40.0
    let answer: SurveyAnswer?
    let onAnswer: (SurveyAnswer) -> Void

    @State private var selectedDate = Date()
    @State private var value = ""
    @State private var hydrated = false
    @State private var showingDateDialog = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = CampaignCanvasTheme.shared.isDark(colorScheme)
        let textColor = CampaignCanvasTheme.shared.color(style.textColor, isDark: isDark)
        let placeholderColor = Color(hex: "#FF9A9AA8") ?? textColor.opacity(0.55)
        let fillColor = CampaignCanvasTheme.shared.color(style.unselectedFill, isDark: isDark)
        let borderColor = CampaignCanvasTheme.shared.color(style.borderColor, isDark: isDark)
        let displayValue = value.isEmpty ? input.placeholder : formatDisplayDate(value, format: input.dateFormat)
        let parsedMinimumDate = parseIsoDate(input.minimumDate ?? "")
        let parsedMaximumDate = parseIsoDate(input.maximumDate ?? "")
        let hasValidDateRange = validDateRange(minimum: parsedMinimumDate, maximum: parsedMaximumDate)
        let minimumDate = hasValidDateRange ? parsedMinimumDate : nil
        let maximumDate = hasValidDateRange ? parsedMaximumDate : nil

        let fieldFontSize = style.fontSize
        let fieldPadding = style.padding
        let scaledRadius = min(max(style.cornerRadius * scaleFactor, 0.0), 32.0)
        let scaledBorderWidth = min(max(style.borderWidth * scaleFactor, 0.5), 4.0)

        ZStack(alignment: .leading) {
            Text(displayValue)
                .font(surveyFont(size: fieldFontSize, weight: style.fontWeight))
                .foregroundColor(value.isEmpty ? placeholderColor : textColor)
                .lineLimit(1)
                .padding(fieldPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: scaledRadius)
                        .fill(fillColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: scaledRadius)
                        .stroke(borderColor, lineWidth: scaledBorderWidth)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedDate = boundedDate(selectedDate, minimum: minimumDate, maximum: maximumDate)
                    showingDateDialog = true
                }
            CanvasSurveyDateDialogPresenter(
                isPresented: $showingDateDialog,
                selectedDate: $selectedDate,
                minimumDate: minimumDate,
                maximumDate: maximumDate,
                onDateChange: update
            )
            .frame(width: 0, height: 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: availableHeight)
        .onAppear {
            guard !hydrated else { return }
            hydrated = true
            value = answer?.values.first ?? ""
            selectedDate = parseIsoDate(value)
                ?? parseIsoDate(input.defaultDate ?? "")
                ?? boundedDate(Date(), minimum: minimumDate, maximum: maximumDate)
        }
        .onChange(of: answer?.values.first) {
            value = $0 ?? ""
            selectedDate = parseIsoDate(value) ?? selectedDate
        }
    }

    private func update(_ date: Date) {
        selectedDate = date
        value = formatIsoDate(date)
        onAnswer(SurveyAnswer(values: [value]))
    }
}

private struct CanvasSurveyDateDialogPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var selectedDate: Date
    let minimumDate: Date?
    let maximumDate: Date?
    let onDateChange: (Date) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        context.coordinator.configure(
            isPresented: isPresented,
            selectedDate: selectedDate,
            minimumDate: minimumDate,
            maximumDate: maximumDate,
            dismiss: { isPresented = false },
            select: { date in
                selectedDate = date
                onDateChange(date)
            }
        )
        context.coordinator.update(from: viewController)
    }

    @MainActor
    final class Coordinator: NSObject {
        private var isPresented = false
        private var selectedDate = Date()
        private var minimumDate: Date?
        private var maximumDate: Date?
        private var dismiss: () -> Void = {}
        private var select: (Date) -> Void = { _ in }
        private weak var alertController: UIAlertController?
        weak var datePicker: UIDatePicker?

        func configure(
            isPresented: Bool,
            selectedDate: Date,
            minimumDate: Date?,
            maximumDate: Date?,
            dismiss: @escaping () -> Void,
            select: @escaping (Date) -> Void
        ) {
            self.isPresented = isPresented
            self.selectedDate = selectedDate
            self.minimumDate = minimumDate
            self.maximumDate = maximumDate
            self.dismiss = dismiss
            self.select = select
        }

        func update(from viewController: UIViewController) {
            if isPresented {
                if alertController == nil {
                    present(from: viewController)
                } else {
                    syncPicker()
                }
            } else if let alertController {
                alertController.dismiss(animated: true)
                self.alertController = nil
            }
        }

        private func present(from viewController: UIViewController) {
            guard viewController.presentedViewController == nil else { return }
            let alert = UIAlertController(title: nil, message: "\n\n\n\n\n\n\n\n\n", preferredStyle: .alert)
            let datePicker = UIDatePicker()
            datePicker.datePickerMode = .date
            if #available(iOS 13.4, *) {
                datePicker.preferredDatePickerStyle = .wheels
            }
            datePicker.minimumDate = minimumDate
            datePicker.maximumDate = maximumDate
            datePicker.date = boundedDate(selectedDate, minimum: minimumDate, maximum: maximumDate)
            alert.view.addSubview(datePicker)
            datePicker.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                datePicker.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 8),
                datePicker.trailingAnchor.constraint(equalTo: alert.view.trailingAnchor, constant: -8),
                datePicker.topAnchor.constraint(equalTo: alert.view.topAnchor, constant: 40),
                datePicker.heightAnchor.constraint(equalToConstant: 216),
            ])
            alert.addAction(
                UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
                    self?.alertController = nil
                    self?.dismiss()
                }
            )
            alert.addAction(
                UIAlertAction(title: "Done", style: .default) { [weak self, weak datePicker] _ in
                    guard let self else { return }
                    let date = datePicker?.date ?? self.selectedDate
                    self.alertController = nil
                    self.select(date)
                    self.dismiss()
                }
            )
            alertController = alert
            self.datePicker = datePicker
            viewController.present(alert, animated: true)
        }

        private func syncPicker() {
            datePicker?.minimumDate = minimumDate
            datePicker?.maximumDate = maximumDate
            datePicker?.date = boundedDate(
                selectedDate,
                minimum: minimumDate,
                maximum: maximumDate
            )
        }
    }
}

private func parseIsoDate(_ input: String) -> Date? {
    let parts = input.split(separator: "-")
    guard parts.count == 3,
          let year = Int(parts[0]),
          let month = Int(parts[1]),
          let day = Int(parts[2])
    else { return nil }
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    return components.date
}

private func boundedDate(_ date: Date, minimum: Date?, maximum: Date?) -> Date {
    if let minimum, date < minimum { return minimum }
    if let maximum, date > maximum { return maximum }
    return date
}

private func validDateRange(minimum: Date?, maximum: Date?) -> Bool {
    guard let minimum, let maximum else { return true }
    return minimum <= maximum
}

private func formatIsoDate(_ date: Date) -> String {
    let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
    return String(
        format: "%04d-%02d-%02d",
        components.year ?? 0,
        components.month ?? 1,
        components.day ?? 1
    )
}

private func formatDisplayDate(_ value: String, format: CanvasSurveyDateFormat) -> String {
    guard let date = parseIsoDate(value) else { return value }
    let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
    let year = components.year ?? 0
    let month = components.month ?? 1
    let day = components.day ?? 1
    switch format {
    case .mmDdYyyy:
        return String(format: "%02d / %02d / %04d", month, day, year)
    case .yyyyMmDd:
        return String(format: "%04d-%02d-%02d", year, month, day)
    case .ddMmYyyy:
        return String(format: "%02d / %02d / %04d", day, month, year)
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
        let metrics = CanvasSurveyAnswerMetrics.compute(
            input: .scale(input),
            hostHeight: host.rect.height,
            style: style
        )
        let scaleFactor = metrics.scaleFactor
        let availableHeight = metrics.availableHeight
        let validationReserve = metrics.validationErrorHeight

        VStack(spacing: 0) {
            ZStack(alignment: .center) {
                switch input.type {
                case .numericNps:
                    NumericNpsScale(
                        values: values,
                        selected: answer?.values.first,
                        circular: host.numericNpsVariant == .circle || input.numericNpsVariant == .circle,
                        style: style,
                        scaleFactor: scaleFactor,
                        availableHeight: availableHeight,
                        onTap: { onAnswer(SurveyAnswer(values: [$0])) }
                    )
                case .rating:
                    let rawSymbol = host.symbolSize > 0 ? host.symbolSize : (input.symbolSize > 0 ? input.symbolSize : 40.0)
                    let scaledSymbol = min(max(rawSymbol * scaleFactor, 16.0), 96.0)
                    RatingScale(
                        values: values,
                        selectedNumber: answer?.values.first.flatMap(Double.init),
                        style: style,
                        scaleFactor: scaleFactor,
                        symbolSize: scaledSymbol,
                        availableHeight: availableHeight,
                        onTap: { onAnswer(SurveyAnswer(values: [$0])) }
                    )
                default:
                    let rawSymbol = host.symbolSize > 0 ? host.symbolSize : (input.symbolSize > 0 ? input.symbolSize : 30.0)
                    let scaledSymbol = min(max(rawSymbol * scaleFactor, 16.0), 96.0)
                    ReactionScale(
                        values: values,
                        selected: answer?.values.first,
                        style: style,
                        scaleFactor: scaleFactor,
                        symbolSize: scaledSymbol,
                        availableHeight: availableHeight,
                        onTap: { onAnswer(SurveyAnswer(values: [$0])) }
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: availableHeight)
            Spacer(minLength: 0)
                .frame(height: validationReserve)
        }
    }
}

private struct NumericNpsScale: View {
    let values: [String]
    let selected: String?
    let circular: Bool
    let style: CanvasSurveyInputStyle
    var scaleFactor: CGFloat = 1.0
    var availableHeight: CGFloat = 36.0
    let onTap: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = CampaignCanvasTheme.shared.isDark(colorScheme)
        GeometryReader { geo in
            let count = max(1, values.count)
            let minGap = max(1.5, 3.0 * scaleFactor)
            let totalMinGap = CGFloat(max(0, count - 1)) * minGap
            let availableWidth = geo.size.width > 0 ? geo.size.width : 32
            let maxCellWidth = max(0, (availableWidth - totalMinGap) / CGFloat(count))
            let maxCellH = availableHeight > 0 ? availableHeight : 32.0
            let tileSize = min(maxCellH, min(32.0 * scaleFactor, maxCellWidth))
            let scaledRadius = circular ? 999.0 : min(max(0.0, style.cornerRadius * scaleFactor), tileSize / 2.0)
            let scaledBorderWidth = min(max(style.borderWidth * scaleFactor, 0.5), 4.0)
            let scaledFontSize = min(max(12.0 * scaleFactor, 8.0), 24.0)
            let spacing = count > 1 ? max(minGap, (availableWidth - tileSize * CGFloat(count)) / CGFloat(count - 1)) : 0

            HStack(spacing: spacing) {
                ForEach(values, id: \.self) { value in
                    let isSelected = selected == value
                    Button { onTap(value) } label: {
                        Text(value)
                            .font(surveyFont(size: scaledFontSize, weight: 600))
                            .foregroundColor(CampaignCanvasTheme.shared.color(isSelected ? style.selectedTextColor : style.textColor, isDark: isDark))
                            .lineLimit(1)
                            .frame(width: tileSize, height: tileSize)
                            .background(
                                RoundedRectangle(cornerRadius: scaledRadius)
                                    .fill(CampaignCanvasTheme.shared.color(isSelected ? style.selectedFill : style.unselectedFill, isDark: isDark))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: scaledRadius)
                                    .stroke(CampaignCanvasTheme.shared.color(isSelected ? style.selectedFill : style.borderColor, isDark: isDark), lineWidth: scaledBorderWidth)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

private struct RatingScale: View {
    let values: [String]
    let selectedNumber: Double?
    let style: CanvasSurveyInputStyle
    var scaleFactor: CGFloat = 1.0
    let symbolSize: CGFloat
    var availableHeight: CGFloat = 40.0
    let onTap: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = CampaignCanvasTheme.shared.isDark(colorScheme)
        let scaledGap = min(max(style.itemGap * scaleFactor, 2.0), 48.0)
        let effectiveSize = availableHeight > 0 ? min(availableHeight, symbolSize) : symbolSize

        GeometryReader { geo in
            let resolvedSymbolSize = ratingSymbolSize(
                availableWidth: geo.size.width,
                count: values.count,
                symbolSize: effectiveSize,
                itemGap: scaledGap
            )
            let spacing = ratingSpacing(
                availableWidth: geo.size.width,
                count: values.count,
                symbolSize: resolvedSymbolSize,
                itemGap: scaledGap
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
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
    var scaleFactor: CGFloat = 1.0
    let symbolSize: CGFloat
    var availableHeight: CGFloat = 30.0
    let onTap: (String) -> Void

    var body: some View {
        let scaledGap = min(max(style.itemGap * scaleFactor, 2.0), 48.0)
        let effectiveSize = availableHeight > 0 ? min(availableHeight, symbolSize) : symbolSize

        GeometryReader { geo in
            let spacing = ratingSpacing(
                availableWidth: geo.size.width,
                count: values.count,
                symbolSize: effectiveSize,
                itemGap: scaledGap
            )
            HStack(spacing: spacing) {
                ForEach(Array(values.enumerated()), id: \.element) { index, value in
                    Button { onTap(value) } label: {
                        ReactionAssetIcon(index: index, size: effectiveSize)
                            .opacity(selected == nil || selected == value ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
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
