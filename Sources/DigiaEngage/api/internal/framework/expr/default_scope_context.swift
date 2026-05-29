import DigiaExpr

/// Mirrors Flutter's DefaultScopeContext.
/// Concrete implementation with a local variable map and an optional enclosing context.
final class DefaultScopeContext: ScopeContext {
    let name: String
    var enclosing: (any ExprContext)?
    private var variables: [String: Any?]

    init(name: String = "", variables: [String: Any?], enclosing: (any ExprContext)? = nil) {
        self.name = name
        self.variables = variables
        self.enclosing = enclosing
    }

    func getValue(_ key: String) -> ExprLookupResult {
        if variables.keys.contains(key) {
            switch variables[key] {
            case .none:
                return ExprLookupResult(found: true, value: ExprValue.from(nil))
            case .some(let value):
                return ExprLookupResult(found: true, value: ExprValue.from(value))
            }
        }
        return enclosing?.getValue(key) ?? ExprLookupResult(found: false, value: nil)
    }

    func copyAndExtend(newVariables: [String: Any?]) -> any ScopeContext {
        var merged = variables
        for (k, v) in newVariables { merged[k] = v }
        return DefaultScopeContext(name: name, variables: merged, enclosing: enclosing)
    }
}
