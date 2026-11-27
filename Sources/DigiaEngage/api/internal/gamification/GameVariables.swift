/// Resolves `{{ }}` tokens in the marketer's text before `init` is built, so the skin reads
/// finished `values` and `slots[].values` and never a token. Every string leaf is resolved,
/// nested objects and arrays included; other values pass through, and a value without `{{`
/// is unchanged.
func resolveGameValues(
    _ values: [String: JSONValue], context: VariableContext
) -> [String: JSONValue] {
    values.mapValues { resolveGameValue($0, context: context) }
}

/// `resolveGameValues` for each slot's values, keeping the slot's `outcomeKey`.
func resolveGameSlots(
    _ slots: [GamificationSlotConfig], context: VariableContext
) -> [GamificationSlotConfig] {
    slots.map {
        GamificationSlotConfig(
            outcomeKey: $0.outcomeKey, values: resolveGameValues($0.values, context: context))
    }
}

private func resolveGameValue(_ value: JSONValue, context: VariableContext) -> JSONValue {
    switch value {
    case .string(let text): return .string(interpolate(text, context: context))
    case .object(let object): return .object(resolveGameValues(object, context: context))
    case .array(let items): return .array(items.map { resolveGameValue($0, context: context) })
    default: return value
    }
}
