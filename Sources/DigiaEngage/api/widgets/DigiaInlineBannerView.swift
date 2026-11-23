import SwiftUI

struct DigiaInlineBannerView: View {
    let config: InlineBannerConfig
    let payload: CEPTriggerPayload

    private var variables: VariableContext {
        buildVariableContext(schemas: config.variableSchemas, cepVars: payload.variables)
    }

    /// The actions whose payload resolves to a value.
    private var actions: [EngageAction] {
        config.actions.filter { !$0.resolved(with: variables).hasEmptyPayload }
    }

    /// Grey while the image is loading or has failed; a loaded image is transparent.
    @State private var imageLoaded = false

    private var imageURL: URL? {
        URL(string: interpolate(config.image.url, context: variables))
    }

    var body: some View {
        Group {
            if actions.isEmpty {
                banner
            } else {
                banner
                    .contentShape(Rectangle())
                    .onTapGesture(perform: handleTap)
            }
        }
        .padding(EdgeInsets(
            top: config.margin.top,
            leading: config.margin.left,
            bottom: config.margin.bottom,
            trailing: config.margin.right
        ))
        .environment(\.digiaCampaignKey, payload.campaignKey)
    }

    @ViewBuilder
    private var banner: some View {
        if config.image.aspectRatio > 0 {
            image
                .aspectRatio(config.image.aspectRatio, contentMode: .fit)
        } else {
            image
                .frame(maxWidth: .infinity)
                .frame(height: config.image.height)
        }
    }

    private var image: some View {
        ZStack {
            if !imageLoaded {
                Color(red: 241 / 255, green: 241 / 255, blue: 245 / 255)
            }
            if let url = imageURL {
                fitted(DigiaCachedImageView(
                    url: url,
                    placeholder: AnyView(BlurHashPlaceholderView(placeholder: config.image.placeholder, fit: config.image.boxFit.rawValue)),
                    onSuccess: { _ in imageLoaded = true },
                    onFailure: { imageLoaded = false }
                ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: config.image.cornerRadius))
        .onChange(of: imageURL) { _ in imageLoaded = false }
    }

    @ViewBuilder
    private func fitted(_ image: DigiaCachedImageView) -> some View {
        switch config.image.boxFit {
        case .cover:
            image.scaledToFill().clipped()
        case .contain:
            image.scaledToFit()
        case .fill:
            image
        }
    }

    private func handleTap() {
        let tappable = actions
        let reportedAction = tappable.first?.resolved(with: variables)
        SDKInstance.shared.inlineReporter.reportBannerClicked(payload: payload, action: reportedAction)
        Task {
            await SDKInstance.shared.executeActionFlow(
                tappable,
                variables: variables,
                campaignKey: payload.campaignKey,
                localActionExecutor: LocalActionExecutor()
            )
        }
    }
}
