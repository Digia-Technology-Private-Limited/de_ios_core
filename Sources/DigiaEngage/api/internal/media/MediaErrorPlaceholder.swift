import SwiftUI

/// What a media wrapper draws, in place of the picture, when its load failed or its URL is
/// unusable and the caller passed no `errorContent`: a box that fills its space, light grey with 8 pt
/// rounded corners and a centred grey label. The same look as Android's `MediaErrorPlaceholder`.
struct MediaErrorPlaceholder: View {
    let label: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(red: 0xF1 / 255, green: 0xF1 / 255, blue: 0xF5 / 255))
            Text(label)
                .font(digiaFont(size: 14))
                .foregroundColor(Color(red: 0x9A / 255, green: 0x9A / 255, blue: 0xAD / 255))
                .multilineTextAlignment(.center)
        }
    }
}
