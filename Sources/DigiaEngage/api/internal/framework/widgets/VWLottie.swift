import Lottie
import SwiftUI
import UIKit

@MainActor
final class VWLottie: VirtualLeafStatelessWidget<LottieProps> {
    override func render(_ payload: RenderPayload) -> AnyView {
        let lottiePath = payload.eval(props.lottiePath)
        guard let lottiePath, !lottiePath.isEmpty else {
            return AnyView(Image(systemName: "exclamationmark.triangle").foregroundStyle(.red))
        }

        let (repeatAnimation, reverseAnimation) = animationFlags(for: props.animationType)
        let onComplete: (() -> Void)? = (!repeatAnimation && props.onComplete != nil)
            ? { payload.executeAction(self.props.onComplete, triggerType: "onComplete") }
            : nil

        return AnyView(
            LottieContainerView(
                path: lottiePath,
                alignment: To.alignment(payload.eval(props.alignment)) ?? .center,
                height: payload.eval(props.height),
                width: payload.eval(props.width),
                animate: payload.eval(props.animate) ?? true,
                frameRate: payload.eval(props.frameRate) ?? 60,
                fit: payload.eval(props.fit),
                repeatAnimation: repeatAnimation,
                reverseAnimation: reverseAnimation,
                onComplete: onComplete
            )
        )
    }

    private func animationFlags(for animationType: String?) -> (Bool, Bool) {
        let value = animationType ?? "loop"
        switch value {
        case "boomerang":
            return (true, true)
        case "once":
            return (false, false)
        case "loop":
            return (true, false)
        default:
            print("[Digia] Unsupported animationType: \(value), defaulting to loop")
            return (true, false)
        }
    }
}

private struct LottieContainerView: View {
    let path: String
    let alignment: Alignment
    let height: Double?
    let width: Double?
    let animate: Bool
    let frameRate: Double
    let fit: String?
    let repeatAnimation: Bool
    let reverseAnimation: Bool
    let onComplete: (() -> Void)?
    
    private var frameWidth: CGFloat? {
        guard let width else { return nil }
        return CGFloat(width)
    }
    
    private var frameHeight: CGFloat? {
        guard let height else { return nil }
        return CGFloat(height)
    }

    var body: some View {
        LottieRepresentable(
            path: path,
            animate: animate,
            frameRate: frameRate,
            fit: fit,
            repeatAnimation: repeatAnimation,
            reverseAnimation: reverseAnimation,
            onComplete: onComplete
        )
        .frame(width: frameWidth, height: frameHeight, alignment: alignment)
    }
}

private struct LottieRepresentable: UIViewRepresentable {
    let path: String
    let animate: Bool
    let frameRate: Double
    let fit: String?
    let repeatAnimation: Bool
    let reverseAnimation: Bool
    let onComplete: (() -> Void)?

    func makeUIView(context: Context) -> LottieHostView {
        let host = LottieHostView()
        host.animationView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(host.animationView)
        NSLayoutConstraint.activate([
            host.animationView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            host.animationView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            host.animationView.topAnchor.constraint(equalTo: host.topAnchor),
            host.animationView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    func updateUIView(_ uiView: LottieHostView, context: Context) {
        uiView.animationView.contentMode = contentMode(for: fit)
        uiView.animationView.loopMode = loopMode(repeatAnimation: repeatAnimation, reverseAnimation: reverseAnimation)
        uiView.animationView.animationSpeed = max(frameRate, 1) / 60

        let playbackKey = "\(animate)-\(repeatAnimation)-\(reverseAnimation)-\(max(frameRate, 1))"

        if uiView.currentPath != path {
            uiView.currentPath = path
            uiView.playbackKey = playbackKey
            context.coordinator.onCompleteTriggered = false
            loadAnimation(path: path, into: uiView) {
                applyPlayback(on: uiView.animationView, coordinator: context.coordinator)
            }
            return
        }

        guard uiView.playbackKey != playbackKey else { return }

        uiView.playbackKey = playbackKey
        context.coordinator.onCompleteTriggered = false
        applyPlayback(on: uiView.animationView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func applyPlayback(on view: LottieAnimationView, coordinator: Coordinator) {
        guard animate else {
            view.stop()
            return
        }

        if repeatAnimation {
            view.play()
            return
        }

        view.currentProgress = 0
        view.play { finished in
            guard finished, !coordinator.onCompleteTriggered else { return }
            coordinator.onCompleteTriggered = true
            onComplete?()
        }
    }

    private func loadAnimation(path: String, into host: LottieHostView, completion: @escaping () -> Void) {
        guard path.hasPrefix("http"), let url = URL(string: path) else {
            print("[Digia] Invalid or non-network lottie URL: \(path)")
            return
        }
        LottieAnimation.loadedFrom(url: url) { animation in
            Task { @MainActor in
                host.animationView.animation = animation
                completion()
            }
        }
    }

    private func loopMode(repeatAnimation: Bool, reverseAnimation: Bool) -> LottieLoopMode {
        if repeatAnimation {
            return reverseAnimation ? .autoReverse : .loop
        }
        return .playOnce
    }

    private func contentMode(for fit: String?) -> UIView.ContentMode {
        switch fit {
        case "cover", "fill":
            return .scaleAspectFill
        case "fitWidth", "fitHeight", "contain":
            return .scaleAspectFit
        default:
            return .scaleAspectFit
        }
    }
}

private final class LottieHostView: UIView {
    let animationView = LottieAnimationView()
    var currentPath: String?
    var playbackKey: String?
}

private final class Coordinator {
    var onCompleteTriggered = false
}
