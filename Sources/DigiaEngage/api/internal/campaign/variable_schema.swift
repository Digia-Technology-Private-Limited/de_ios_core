// MARK: - Variable schema + raw-JSON normalisation
//
// A `VariableSchema` is one declared campaign variable: its name, its type
// ("string" | "number") and the fallbackValue used when CEP supplies nothing.

struct VariableSchema: Equatable {
    let name: String
    let type: String        // "string" | "number"
    let fallbackValue: String
}

/// Normalises a raw variable definition into a `VariableSchema` (D29).
func normalizeVariable(name: String, type rawType: String?, fallbackValue: String?, sampleValue: String?) -> VariableSchema {
    VariableSchema(
        name: name,
        type: rawType == "number" ? "number" : "string",
        fallbackValue: fallbackValue ?? sampleValue ?? ""
    )
}
