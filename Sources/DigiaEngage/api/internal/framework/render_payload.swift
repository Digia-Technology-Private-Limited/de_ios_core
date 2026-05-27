import SwiftUI

@MainActor
struct RenderPayload {
    let resources: ResourceProvider
    let scopeContext: any ScopeContext
    let actionExecutor: ActionExecutor
    let localStateStore: StateContext?

    init(
        resources: ResourceProvider,
        scopeContext: (any ScopeContext)? = nil,
        actionExecutor: ActionExecutor? = nil,
        localStateStore: StateContext? = nil
    ) {
        self.resources = resources
        let rootContext: any ScopeContext = scopeContext ?? AppStateExprContext(
            values: SDKInstance.shared.appState.mapValues(\.anyValue),
            streams: SDKInstance.shared.appStateStreams.mapValues { $0 as Any }
        )
        self.scopeContext = rootContext
        self.actionExecutor = actionExecutor ?? ActionExecutor()
        self.localStateStore = localStateStore
    }

    func resolveColor(_ value: String?) -> Color? {
        resources.getColor(value)
    }

    func evalColor(_ value: String?, scopeContext incoming: (any ExprContext)? = nil) -> Color? {
        guard let value else { return nil }
        return resolveColor(ExprOr<String>.value(value).resolve(in: chainContext(incoming)))
    }

    func eval(_ value: ExprOr<String>?, scopeContext incoming: (any ExprContext)? = nil) -> String? {
        value?.resolve(in: chainContext(incoming))
    }

    func eval(_ value: ExprOr<Bool>?, scopeContext incoming: (any ExprContext)? = nil) -> Bool? {
        value?.resolve(in: chainContext(incoming))
    }

    func eval(_ value: ExprOr<Int>?, scopeContext incoming: (any ExprContext)? = nil) -> Int? {
        value?.resolve(in: chainContext(incoming))
    }

    func eval(_ value: ExprOr<Double>?, scopeContext incoming: (any ExprContext)? = nil) -> Double? {
        value?.resolve(in: chainContext(incoming))
    }

    func evalJSONValue(_ value: JSONValue?, scopeContext incoming: (any ExprContext)? = nil) -> JSONValue? {
        guard let value else { return nil }
        return ExpressionUtil.evaluateNestedExpressions(value, in: chainContext(incoming))
    }

    func evalAny(_ value: JSONValue?, scopeContext incoming: (any ExprContext)? = nil) -> Any? {
        ExpressionUtil.evaluateNestedExpressionsToAny(value, in: chainContext(incoming))
    }

    func evalColor(_ value: ExprOr<String>?, scopeContext incoming: (any ExprContext)? = nil) -> Color? {
        resolveColor(eval(value, scopeContext: incoming))
    }

    func executeAction(
        _ actionFlow: ActionFlow?,
        triggerType: String? = nil,
        scopeContext overrideContext: (any ExprContext)? = nil
    ) {
        actionExecutor.execute(
            actionFlow,
            appConfig: resources.appConfigStore,
            scopeContext: overrideContext ?? scopeContext,
            triggerType: triggerType,
            localStateStore: localStateStore
        )
    }

    func copyWithChainedContext(_ context: any ScopeContext) -> RenderPayload {
        copyWith(scopeContext: chainedScopeContext(context))
    }

    func copyWith(
        scopeContext: (any ScopeContext)? = nil,
        localStateStore: StateContext? = nil
    ) -> RenderPayload {
        RenderPayload(
            resources: resources,
            scopeContext: scopeContext ?? self.scopeContext,
            actionExecutor: actionExecutor,
            localStateStore: localStateStore ?? self.localStateStore
        )
    }

    /// Chains `incoming` with `scopeContext` at its tail. Returns `incoming` (or `scopeContext` if nil).
    private func chainContext(_ incoming: (any ExprContext)?) -> any ExprContext {
        guard let incoming else { return scopeContext }
        incoming.addContextAtTail(scopeContext)
        return incoming
    }

    /// Like `chainContext` but requires and returns `any ScopeContext`.
    private func chainedScopeContext(_ incoming: any ScopeContext) -> any ScopeContext {
        incoming.addContextAtTail(scopeContext)
        return incoming
    }
}
