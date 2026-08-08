internal func logAnchorlessTrace(_ trace: AnchorlessTrace) {
    guard DigiaDebugDetection.isDebugBuild() else { return }
    DigiaLog.verbose(
        "[Anchorless] phase=\(trace.phase.rawValue)"
            + " outcome=\(trace.failure?.rawValue ?? "resolved")"
            + " variantId=\(trace.variantId ?? "-")"
    )
}
