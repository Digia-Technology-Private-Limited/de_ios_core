import SwiftUI

/// Settings row matching the platform-native "label | divider | switch" style.
/// With `onTap` set, the label opens an L2 screen and the switch is a separate
/// tap target (divider marks the split). With `onTap` nil, there's only one
/// tap target — no divider, whole row toggles.
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
