import Combine

/// Presentation wiring owns the concrete dependencies. `GuideOverlayView` is a
/// blind consumer of `resolveTarget`; it does not know the runtime or capture
/// trees and it does not read the anchor registry directly.
@MainActor
final class GuideTargetAdapterStore: ObservableObject {
    static let shared = GuideTargetAdapterStore()

    let adapter: GuideTargetAdapter
    private var registryObservation: AnyCancellable?

    private init() {
        let registry = AnchorRegistry.shared
        adapter = GuideTargetAdapter(
            anchorSource: RegistryAnchorSource(registry: registry),
            anchorlessRuntime: AnchorlessRuntime(
                snapshotProvider: UIWindowSnapshotProvider(),
                deviceStateProvider: UIKitDeviceStateProvider(
                    currentPageKeySource: { SDKInstance.shared.currentScreenForAnchorless }
                ),
                diagnostics: AnchorlessDiagnostics.makeDefaultSink()
            )
        )
        registryObservation = registry.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

@MainActor
private struct RegistryAnchorSource: RegisteredAnchorSource {
    let registry: AnchorRegistry

    func target(forAnchorKey anchorKey: String) -> RegisteredAnchorMeasurement? {
        guard let rect = registry.getRect(for: anchorKey) else { return nil }
        return RegisteredAnchorMeasurement(
            rect: rect,
            cornerRadius: registry.getCornerRadius(for: anchorKey)
        )
    }
}
