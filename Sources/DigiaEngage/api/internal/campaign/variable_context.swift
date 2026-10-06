private let log = DigiaLogger()

// MARK: - Variable context
//
// A `VariableContext` is the resolved scope handed to interpolation: each
// variable's string value (CEP → fallback → "") plus its declared type, so the
// arithmetic evaluator knows which identifiers are numbers.

struct VariableContext: Equatable {
    let values: [String: String]
    let types: [String: String]

    static let empty = VariableContext(values: [:], types: [:])
}

/// Builds a `VariableContext` from schemas, letting non-empty CEP values win (D3′).
func buildVariableContext(
    schemas: [VariableSchema],
    cepVars: [String: String]?,
    campaignKey: String? = nil
) -> VariableContext {
    var values: [String: String] = [:]
    var types: [String: String] = [:]
    for schema in schemas {
        let cep = cepVars?[schema.name] ?? ""
        values[schema.name] = (cep != "") ? cep : schema.fallbackValue
        // Callers that rebuild each frame pass no key, so they stay silent.
        if let campaignKey, cep == "", schema.fallbackValue == "" {
            log.w(
                "Variable has no CEP value and no fallback (variable=\(schema.name))",
                campaign: campaignKey,
                stage: .render,
                reason: TimelineReason.missingVariable,
                extras: ["variable": schema.name]
            )
        }
        types[schema.name] = schema.type
    }
    return VariableContext(values: values, types: types)
}
