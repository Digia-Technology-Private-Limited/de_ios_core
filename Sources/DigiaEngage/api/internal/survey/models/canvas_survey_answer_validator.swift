import Foundation

private let canvasSurveyEmailRegex = try? NSRegularExpression(
    pattern: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
)

struct CanvasSurveyAnswerValidator {
    func isComplete(input: CanvasSurveyWireInput?, answer: SurveyAnswer?) -> Bool {
        validationError(input: input, answer: answer) == nil
    }

    func validationError(input: CanvasSurveyWireInput?, answer: SurveyAnswer?) -> String? {
        guard let input, input.required else { return nil }
        guard answer?.isAnswered == true else { return missingAnswerMessage(for: input) }
        let values = answer?.values ?? []
        switch input {
        case .choice(let input):
            if let maximumSelections = input.maximumSelections, values.count > maximumSelections {
                return "Select at most \(maximumSelections) \(optionWord(maximumSelections))"
            }
            return values.isEmpty ? "Select an option" : nil
        case .field(let input):
            return fieldValidationError(
                type: input.type,
                value: values.first ?? "",
                minLength: input.minLength,
                maxLength: input.maxLength,
                minimum: input.minimum,
                maximum: input.maximum
            )
        case .scale(let input):
            return scaleValidationError(values.first, minimum: input.minimum, maximum: input.maximum)
        }
    }

    func autoAdvanceEligible(input: CanvasSurveyWireInput?) -> Bool {
        switch input {
        case .choice(let input):
            return input.type != .multiSelect
        case .scale:
            return true
        case .field, nil:
            return false
        }
    }

    private func fieldValidationError(
        type: CanvasSurveyInputType,
        value: String,
        minLength: Int?,
        maxLength: Int?,
        minimum: Double?,
        maximum: Double?
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "This field is required" }
        if let minLength, value.count < minLength { return "Enter at least \(minLength) characters" }
        if let maxLength, value.count > maxLength { return "Enter at most \(maxLength) characters" }
        if type == .number {
            guard let parsed = Double(trimmed) else { return "Enter a valid number" }
            if let minimum, parsed < minimum { return "Must be at least \(formatNumber(minimum))" }
            if let maximum, parsed > maximum { return "Must be at most \(formatNumber(maximum))" }
        }
        if type == .email && !emailIsValid(trimmed) {
            return "Enter a valid email address"
        }
        return nil
    }

    private func scaleValidationError(_ value: String?, minimum: Double, maximum: Double) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = Double(trimmed) else {
            return "Choose a rating"
        }
        return parsed >= minimum && parsed <= maximum ? nil : "Choose a rating"
    }

    private func emailIsValid(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return canvasSurveyEmailRegex?.firstMatch(in: value, range: range) != nil
    }

    private func missingAnswerMessage(for input: CanvasSurveyWireInput) -> String {
        switch input {
        case .choice(let input):
            return input.type == .multiSelect ? "Select at least one option" : "Select an option"
        case .field:
            return "This field is required"
        case .scale:
            return "Choose a rating"
        }
    }

    private func optionWord(_ count: Int) -> String {
        return count == 1 ? "option" : "options"
    }

    private func formatNumber(_ value: Double) -> String {
        return value.rounded() == value ? String(Int(value)) : String(value)
    }
}
