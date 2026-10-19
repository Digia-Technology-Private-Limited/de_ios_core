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
func buildVariableContext(schemas: [VariableSchema], cepVars: [String: String]?) -> VariableContext {
    var values: [String: String] = [:]
    var types: [String: String] = [:]
    for schema in schemas {
        values[schema.name] = schema.resolve(cepVars?[schema.name])
        types[schema.name] = schema.type
    }
    return VariableContext(values: values, types: types)
}

/// Reports each declared variable with no CEP value and no fallback. Call once per start, never from a view body.
func reportMissingVariables(_ schemas: [VariableSchema], payload: CEPTriggerPayload) {
    for schema in schemas where (payload.variables?[schema.name] ?? "") == "" && !schema.hasFallback {
        log.w(
            "Variable has no CEP value and no fallback (variable=\(schema.name))",
            campaign: payload.campaignKey,
            stage: .render,
            reason: TimelineReason.missingVariable,
            extras: ["variable": schema.name]
        )
    }
}

/// Looks up the runtime value of each context variable in `schemas` — `user.<key>` from
/// `userAttributes`, `event.<key>` from `eventProperties` — keyed by its token. Custom
/// variables are skipped: the CEP payload carries those. `buildVariableContext` applies
/// types and fallbacks, so a CEP-decided campaign, which declares no context variables,
/// gets an empty map.
func bindContextVariables(
    _ schemas: [VariableSchema],
    userAttributes: [String: Any],
    eventProperties: [String: Any] = [:]
) -> [String: String] {
    var bound: [String: String] = [:]
    for schema in schemas {
        guard let dot = schema.name.firstIndex(of: ".") else { continue }
        let key = String(schema.name[schema.name.index(after: dot)...])
        let raw: Any?
        switch schema.name[..<dot] {
        case userNamespace[...]: raw = userAttributes[key]
        case eventNamespace[...]: raw = eventProperties[key]
        default: raw = nil
        }
        bound[schema.name] = schema.resolve(raw)
    }
    return bound
}
