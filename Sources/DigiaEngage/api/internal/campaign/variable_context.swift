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
        let cep = cepVars?[schema.name] ?? ""
        values[schema.name] = (cep != "") ? cep : schema.fallbackValue
        types[schema.name] = schema.type
    }
    return VariableContext(values: values, types: types)
}
