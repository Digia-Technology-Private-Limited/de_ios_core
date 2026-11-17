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
    reportVariableTypeMismatches(schemas, payload: payload)
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

private let maxMismatches = 10
private let maxSampleLength = 32

/// Shortens a mismatch sample to at most 32 Unicode scalars: first part + "…" + last part
/// (16 + 1 + 15). A cut never lands inside a grapheme cluster, so it may come out shorter.
/// Android and Flutter apply the same rule; the shared sample table in the tests pins all three to one table.
func truncatedMismatchSample(_ sample: String) -> String {
    let scalars = Array(sample.unicodeScalars)
    guard scalars.count > maxSampleLength else { return sample }
    var boundaries: Set<Int> = [0]
    var offset = 0
    for character in sample {
        offset += character.unicodeScalars.count
        boundaries.insert(offset)
    }
    var head = maxSampleLength / 2
    while !boundaries.contains(head) { head -= 1 }
    var tail = scalars.count - (maxSampleLength - 1) / 2
    while !boundaries.contains(tail) { tail += 1 }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: scalars[..<head])
    out.append("\u{2026}")
    out.append(contentsOf: scalars[tail...])
    return String(out)
}

/// Reports once, as a `variable_type_mismatch` health event, every declared variable whose CEP value
/// does not fit its declared type (at most 10, each sample shortened to 32 characters). Call once per
/// start, never from a view body.
func reportVariableTypeMismatches(
    _ schemas: [VariableSchema], payload: CEPTriggerPayload, sink: HealthSink = .shared
) {
    var mismatches: [[String: String]] = []
    for schema in schemas {
        let raw = payload.variables?[schema.name]
        guard schema.misfits(raw) else { continue }
        if mismatches.count >= maxMismatches { break }
        mismatches.append([
            "name": schema.name,
            "expected": schema.type,
            "sample": truncatedMismatchSample(raw ?? ""),
        ])
    }
    guard !mismatches.isEmpty else { return }
    sink.reportVariableTypeMismatch(campaignKey: payload.campaignKey, mismatches: mismatches)
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
