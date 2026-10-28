import CoreText
import Foundation
@testable import DigiaEngage

/// The shared Roboto (`sdk_testing_fixtures/fonts/`) every stack's goldens draw with, handed to the
/// SDK as the host `fontFamily` exactly as a customer app would, so fixtures with no authored family
/// resolve through `DigiaFont` to the same face on iOS, Android and Flutter.
enum GoldenFonts {
    static let family = "Roboto"

    private static let registered: Void = {
        guard let workspace = FixtureLoader.workspaceURL() else {
            preconditionFailure("No de_workspace above \(#filePath): the golden fonts live in its sdk_testing_fixtures/fonts/")
        }
        let directory = workspace.appendingPathComponent("sdk_testing_fixtures/fonts", isDirectory: true)
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "ttf" }
        precondition(!urls.isEmpty, "No Roboto TTFs in \(directory.path)")
        var errors: Unmanaged<CFArray>?
        guard CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, &errors) else {
            preconditionFailure("Registering the golden fonts failed: \(String(describing: errors?.takeRetainedValue()))")
        }
    }()

    /// Registers the TTFs once and sets Roboto as the SDK's host font. `resetForTesting` clears the
    /// font, so mounts call this every time; paths through `Digia.initialize` pass the family in
    /// `DigiaConfig` instead.
    @MainActor
    static func install() {
        _ = registered
        SDKInstance.shared.font = DigiaFont(fontFamily: family)
    }

    /// Restores the SDK's default font so tests mounted after a golden don't inherit Roboto.
    @MainActor
    static func uninstall() {
        SDKInstance.shared.font = DigiaFont()
    }
}
