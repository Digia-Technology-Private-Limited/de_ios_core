import Foundation

private let canvasSurveyEmailRegex = try? NSRegularExpression(
    pattern: #"^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#
)

struct CanvasSurveyAnswerValidator {
    func isComplete(input: CanvasSurveyWireInput?, answer: SurveyAnswer?) -> Bool {
        guard let input, input.required else { return true }
        guard answer?.isAnswered == true else { return false }
        let values = answer?.values ?? []
        switch input {
        case .choice(let input):
            if let maximumSelections = input.maximumSelections, values.count > maximumSelections {
                return false
            }
            return !values.isEmpty
        case .field(let input):
            return fieldComplete(
                type: input.type,
                value: values.first ?? "",
                minLength: input.minLength,
                maxLength: input.maxLength,
                minimum: input.minimum,
                maximum: input.maximum
            )
        case .scale(let input):
            return numberInRange(values.first, minimum: input.minimum, maximum: input.maximum)
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

    private func fieldComplete(
        type: CanvasSurveyInputType,
        value: String,
        minLength: Int?,
        maxLength: Int?,
        minimum: Double?,
        maximum: Double?
    ) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if let minLength, value.count < minLength { return false }
        if let maxLength, value.count > maxLength { return false }
        if type == .number {
            guard let parsed = Double(trimmed) else { return false }
            if let minimum, parsed < minimum { return false }
            if let maximum, parsed > maximum { return false }
        }
        if type == .email && !emailIsValid(trimmed) {
            return false
        }
        return true
    }

    private func numberInRange(_ value: String?, minimum: Double, maximum: Double) -> Bool {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let parsed = Double(trimmed) else {
            return false
        }
        return parsed >= minimum && parsed <= maximum
    }

    private func emailIsValid(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return canvasSurveyEmailRegex?.firstMatch(in: value, range: range) != nil
    }
}
