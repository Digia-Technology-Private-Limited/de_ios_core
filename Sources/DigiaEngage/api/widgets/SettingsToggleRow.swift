import SwiftUI

/// A settings row matching the platform-native "label | divider | switch" style (e.g.
/// iOS/Android system settings — Wi-Fi Calling, Bluetooth, …), used only when there's a
/// second tap target to disambiguate from the switch: tapping the label (`title`/
/// `subtitle`) triggers `onTap` (e.g. opens an L2 screen), while the `Toggle` is a
/// separate tap target with its own binding — the divider signals that split.
///
/// Pass `onTap` as `nil` for a row with no drill-down (just a plain toggle, e.g. "Digia
/// bubble") — there's only one tap target then, so it drops the divider and makes the
/// whole row tap to toggle, matching how a plain switch row behaves everywhere else.
@MainActor
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    var onTap: (() -> Void)? = nil
    @Binding var isOn: Bool

    var body: some View {
        if let onTap {
            HStack {
                Button(action: onTap) { label }
                    .buttonStyle(.plain)
                Spacer()
                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1, height: 24)
                    .padding(.trailing, 12)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
            }
        } else {
            HStack {
                label
                Spacer()
                Toggle("", isOn: $isOn)
                    .labelsHidden()
            }
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
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
