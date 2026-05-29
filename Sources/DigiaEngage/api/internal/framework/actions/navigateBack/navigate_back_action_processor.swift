import Foundation

struct NavigateBackAction: Sendable {
    let actionType: ActionType = .navigateBack
    let disableActionIf: ExprOr<Bool>?
    let data: [String: JSONValue]
}

@MainActor
struct NavigateBackProcessor {
    let processorType: ActionType = .navigateBack

    func execute(action: NavigateBackAction, context: ActionProcessorContext) async throws {
        let maybe = (action.data["maybe"]?.deepEvaluate(in: context.scopeContext) as? Bool) ?? false

        let result = action.data["result"].map {
            ExpressionUtil.evaluateNestedExpressions($0, in: context.scopeContext)
        }

        let overlayController = SDKInstance.shared.controller
        let navController = SDKInstance.shared.navigationController

        if overlayController.activeDialog != nil {
            overlayController.dismissDialog(result: result)
            ViewControllerUtil.dismissPresented()
            return
        }
        if overlayController.activeBottomSheet != nil {
            if let transition = overlayController.bottomSheetTransition {
                transition.animateDismiss {
                    if overlayController.bottomSheetRendersInHost {
                        overlayController.dismissBottomSheet(result: result)
                        SDKInstance.shared.didDismissBottomSheet()
                    } else {
                        ViewControllerUtil.dismissPresented(animated: false) {
                            overlayController.dismissBottomSheet(result: result)
                            SDKInstance.shared.didDismissBottomSheet()
                        }
                    }
                }
            } else {
                overlayController.dismissBottomSheet(result: result)
                SDKInstance.shared.didDismissBottomSheet()
                if !overlayController.bottomSheetRendersInHost {
                    ViewControllerUtil.dismissPresented(animated: true)
                }
            }
            return
        }

        if maybe && navController.path.isEmpty { return }
        navController.pop(result: result)

        // Fallback for UIKit-embedded navigation only when a NavigationStack is not mounted.
        if navController.path.isEmpty && !SDKInstance.shared.isNavigationMounted {
            ViewControllerUtil.popNavigation()
        }
    }
}
