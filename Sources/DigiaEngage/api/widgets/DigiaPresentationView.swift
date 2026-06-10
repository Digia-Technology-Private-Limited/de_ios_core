import SwiftUI

@MainActor
struct DigiaPresentationView: View {
    let presentation: DigiaViewPresentation

    var body: some View {
        fallbackContent
    }

    private var fallbackContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = presentation.title {
                Text(title).font(.headline)
            }
            if let text = presentation.text {
                Text(text)
            }
        }
        .padding(16)
    }
}
