import SwiftUI

/// A settings row matching the platform-native "label | divider | switch" style (e.g.
/// iOS/Android system settings — Wi-Fi Calling, Bluetooth, …): tapping the label
/// (`title`/`subtitle`) triggers `onTap` (e.g. flips a hidden `NavigationLink(isActive:)`
/// to open an L2 screen), while the `Toggle` is a separate tap target with its own
/// binding. `onTap` is scoped to just the label (via a plain-style `Button`), not the
/// whole row, so it never competes with the `Toggle`'s own tap handling. Pass `onTap` as
/// `nil` for a row with no drill-down (just a plain toggle row).
@MainActor
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    var onTap: (() -> Void)? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Group {
                if let onTap {
                    Button(action: onTap) { label }
                        .buttonStyle(.plain)
                } else {
                    label
                }
            }
            Spacer()
            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1, height: 24)
                .padding(.trailing, 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }
}
