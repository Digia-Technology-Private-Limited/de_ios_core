import SwiftUI

@MainActor
final class CampaignCanvasTheme: ObservableObject {
    static let shared = CampaignCanvasTheme()
    @Published private(set) var mode: DigiaThemeMode = .auto
    func update(_ mode: DigiaThemeMode) { self.mode = mode }
    func isDark(_ system: ColorScheme) -> Bool {
        switch mode { case .light: false; case .dark: true; case .auto: system == .dark }
    }
    func color(_ value: CampaignColor, isDark: Bool) -> Color {
        Color(hex: isDark ? value.darkHex : value.lightHex) ?? .clear
    }
    func mediaURL(_ source: CampaignCanvasMediaSource, isDark: Bool) -> String {
        isDark && !(source.darkUrl ?? "").isEmpty ? source.darkUrl! : source.url
    }
}
