// Module: anchorless/runtime
//
// The eligibility gate — native runtime contract §6. Evaluated after `prepare` and
// before `resolve`, and owned here rather than by the solver because the solver's
// snapshot carries three fields and nothing else.
//
// The orientation and form-factor checks survive precisely *because* the Beta is
// portrait-phone only: without them a rotated phone or a tablet resolves a portrait
// rule against a landscape window and paints a confidently wrong highlight instead
// of showing nothing.

import UIKit

internal enum AnchorlessOrientation: String, Equatable, Sendable, CaseIterable {
    case portrait
    case landscape
}

internal enum AnchorlessFormFactor: String, Equatable, Sendable, CaseIterable {
    case phone
    case tablet
}

/// The device state the gate reads. Page identity belongs to neither tree: the
/// existing screen tracker is injected as a value.
internal struct AnchorlessDeviceState: Equatable, Sendable {
    /// `nil` when the host app has never called `setCurrentScreen`. An app that
    /// never sets the current screen can neither capture nor display an Anchorless
    /// Spotlight; it fails closed here.
    internal let currentPageKey: String?
    internal let orientation: AnchorlessOrientation
    internal let formFactor: AnchorlessFormFactor

    internal init(
        currentPageKey: String?,
        orientation: AnchorlessOrientation,
        formFactor: AnchorlessFormFactor
    ) {
        self.currentPageKey = currentPageKey
        self.orientation = orientation
        self.formFactor = formFactor
    }
}

/// The seam the runtime reads device eligibility through.
@MainActor
internal protocol AnchorlessDeviceStateProvider {
    func currentDeviceState() -> AnchorlessDeviceState
}

internal enum AnchorlessEligibilityGate {
    /// Returns the gate failure, or `nil` when the device is eligible.
    ///
    /// Checked in the order the contract tabulates them: page key, orientation,
    /// form factor.
    internal static func evaluate(
        prepared: PreparedAnchorlessTarget,
        device: AnchorlessDeviceState
    ) -> AnchorlessFailure? {
        guard let currentPageKey = device.currentPageKey,
              currentPageKey == prepared.pageKey
        else {
            return .pageKeyMismatch
        }
        guard device.orientation == .portrait else { return .unsupportedOrientation }
        guard device.formFactor == .phone else { return .unsupportedFormFactor }
        return nil
    }
}

/// The production provider. Orientation is read from the window's own geometry
/// rather than from `UIDevice.orientation`, which reports face-up/face-down and
/// lags the interface.
@MainActor
internal struct UIKitDeviceStateProvider: AnchorlessDeviceStateProvider {
    private let currentPageKeySource: @MainActor () -> String?
    private let windowSource: @MainActor () -> UIWindow?

    internal init(
        currentPageKeySource: @escaping @MainActor () -> String?,
        windowSource: @escaping @MainActor () -> UIWindow? = { UIWindowSnapshotProvider.keyWindow() }
    ) {
        self.currentPageKeySource = currentPageKeySource
        self.windowSource = windowSource
    }

    internal func currentDeviceState() -> AnchorlessDeviceState {
        let bounds = windowSource()?.bounds ?? .zero
        let orientation: AnchorlessOrientation = bounds.height >= bounds.width ? .portrait : .landscape
        let formFactor: AnchorlessFormFactor =
            UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .phone
        return AnchorlessDeviceState(
            currentPageKey: currentPageKeySource(),
            orientation: orientation,
            formFactor: formFactor
        )
    }
}
