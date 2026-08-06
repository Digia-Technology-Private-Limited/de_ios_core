// Module: anchorless/runtime
//
// Diagnostics — native runtime contract §9 and handoff decision **H5**.
//
// Two hard rules from the contract:
//   1. The sink is **never a network transport**. This Beta has no quality
//      telemetry, and adding a silent one here would invent rollout policy.
//   2. `anchorless/solver` does not know the sink exists. `prepare` and `resolve`
//      return the trace in their result and the runtime decides what to do with it.
//
// H5 fixes the shipped adapter: a debug-only 20-entry in-memory ring, and a
// **no-op object** in release — not a disabled ring. T-7 therefore passes
// structurally rather than because a runtime flag happened to be off.

import Foundation

/// The seam. One of the three injected seams of §10; the recording fake used by
/// tests crosses exactly this interface.
internal protocol DiagnosticsSink: AnyObject, Sendable {
    func record(_ trace: AnchorlessTrace)
}

/// The release binding. Holds nothing, records nothing, and cannot be switched on.
internal final class NoOpDiagnosticsSink: DiagnosticsSink {
    internal init() {}
    internal func record(_ trace: AnchorlessTrace) {}
}

/// The debug binding: the last 20 traces, in memory, never uploaded, never
/// persisted, cleared on process termination (retention class "Local SDK capture
/// diagnostics").
///
/// Content-free by construction: `AnchorlessTrace` carries only enums, numbers and
/// authored identifiers, so there is no field a host string could occupy.
internal final class AnchorlessDiagnosticsRing: DiagnosticsSink, @unchecked Sendable {
    internal static let capacity = 20

    private let lock = NSLock()
    private var storage: [AnchorlessTrace] = []

    internal init() {}

    internal func record(_ trace: AnchorlessTrace) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(trace)
        if storage.count > Self.capacity {
            storage.removeFirst(storage.count - Self.capacity)
        }
        DigiaLog.verbose(
            "[Anchorless] phase=\(trace.phase.rawValue)"
                + " outcome=\(trace.failure?.rawValue ?? "resolved")"
                + " variantId=\(trace.variantId ?? "-")"
        )
    }

    /// Oldest first.
    internal var traces: [AnchorlessTrace] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    internal func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

internal enum AnchorlessDiagnostics {
    /// The binding decision, in one place. A release build gets an object that
    /// cannot record, not a ring with recording disabled.
    internal static func makeDefaultSink(
        isDebugBuild: Bool = DigiaDebugDetection.isDebugBuild()
    ) -> DiagnosticsSink {
        isDebugBuild ? AnchorlessDiagnosticsRing() : NoOpDiagnosticsSink()
    }
}
