import Foundation

struct CanvasSurveyAnswerMetrics: Equatable {
    let scaleFactor: CGFloat
    let validationErrorHeight: CGFloat
    let availableHeight: CGFloat

    static let baseValidationErrorHeight: CGFloat = 16.0
    static let minValidationErrorHeight: CGFloat = 12.0
    static let maxValidationErrorHeight: CGFloat = 20.0

    static func compute(
        input: CanvasSurveyWireInput?,
        hostHeight: CGFloat,
        style: CanvasSurveyInputStyle? = nil
    ) -> CanvasSurveyAnswerMetrics {
        let effectiveHeight = hostHeight > 0 ? hostHeight : 100.0
        let factor = computeFactor(input: input, effectiveHeight: effectiveHeight, style: style)
        let errorFactor = min(max(1.0 + (factor - 1.0) * 0.2, 0.75), 1.25)
        let errorH = min(
            max(baseValidationErrorHeight * errorFactor, minValidationErrorHeight),
            maxValidationErrorHeight
        )
        let available = max(0.0, effectiveHeight - errorH)
        return CanvasSurveyAnswerMetrics(
            scaleFactor: factor,
            validationErrorHeight: errorH,
            availableHeight: available
        )
    }

    private static func computeFactor(
        input: CanvasSurveyWireInput?,
        effectiveHeight: CGFloat,
        style: CanvasSurveyInputStyle?
    ) -> CGFloat {
        guard let input else {
            return min(max(effectiveHeight / 80.0, 0.4), 2.5)
        }
        switch input {
        case .choice(let choiceInput):
            let effectiveStyle = style ?? choiceInput.style
            let rows = CGFloat(choiceRowCount(input: choiceInput, style: effectiveStyle))
            let baselineTileH = max(
                36.0,
                effectiveStyle.padding * 2.0 + effectiveStyle.fontSize * 1.4
            )
            let itemGap = effectiveStyle.itemGap
            let baselineHeight = rows * baselineTileH +
                max(0.0, rows - 1.0) * itemGap +
                baseValidationErrorHeight
            return min(max(effectiveHeight / baselineHeight, 0.4), 2.5)

        case .field(let fieldInput):
            let effectiveStyle = style ?? fieldInput.style
            let isLongText = fieldInput.type == .longText
            let baselineFieldH = isLongText ? 80.0 : max(
                40.0,
                effectiveStyle.padding * 2.0 + effectiveStyle.fontSize * 1.4
            )
            let baselineHeight = baselineFieldH + baseValidationErrorHeight
            return min(max(effectiveHeight / baselineHeight, 0.4), 2.5)

        case .scale(let scaleInput):
            let baselineScaleH: CGFloat
            switch scaleInput.type {
            case .numericNps:
                baselineScaleH = 36.0
            case .rating:
                baselineScaleH = scaleInput.symbolSize > 0 ? scaleInput.symbolSize : 40.0
            default:
                baselineScaleH = scaleInput.symbolSize > 0 ? scaleInput.symbolSize : 30.0
            }
            let baselineHeight = baselineScaleH + baseValidationErrorHeight
            return min(max(effectiveHeight / baselineHeight, 0.4), 2.5)
        }
    }

    private static func choiceRowCount(
        input: CanvasSurveyChoiceInput,
        style: CanvasSurveyInputStyle?
    ) -> Int {
        let count = input.options.count
        if count <= 0 { return 1 }
        let effectiveStyle = style ?? input.style
        let layout = effectiveStyle.layout
        switch layout {
        case .row:
            return 1
        case .grid:
            let columns = max(1, effectiveStyle.columns > 1 ? effectiveStyle.columns : 2)
            return Int(ceil(Double(count) / Double(columns)))
        case .list:
            return count
        }
    }
}
