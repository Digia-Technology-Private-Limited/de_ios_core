import Foundation

/// Resolves `{{ }}` tokens in the marketer's text before it reaches the skin: the skin gets
/// finished text in `init.values` and `init.slots[].values` and never sees a token.
///
/// Every string leaf is resolved (nested objects and arrays included); other values pass
/// through. A value without `{{` is untouched, so a campaign with no variables sends exactly
/// what it did before. Pure and total: it cannot throw.
func resolveGameValues(_ values: [String: JSONValue], context: VariableContext) -> [String: JSONValue] {
    values.mapValues { resolveGameValue($0, context: context) }
}

/// `resolveGameValues` for every slot, keeping each slot's `outcomeKey`.
func resolveGameSlots(_ slots: [GamificationSlotConfig], context: VariableContext) -> [GamificationSlotConfig] {
    slots.map { GamificationSlotConfig(outcomeKey: $0.outcomeKey, values: resolveGameValues($0.values, context: context)) }
}

private func resolveGameValue(_ value: JSONValue, context: VariableContext) -> JSONValue {
    switch value {
    case .string(let text): return .string(interpolate(text, context: context))
    case .object(let object): return .object(resolveGameValues(object, context: context))
    case .array(let items): return .array(items.map { resolveGameValue($0, context: context) })
    default: return value
    }
}
