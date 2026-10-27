import UIKit

/// Reads what a real window shows, from the view hierarchy.
@MainActor
enum UIProbe {
    /// Every text on screen, from text views and labels, in hierarchy order.
    static func texts(in view: UIView) -> [String] {
        var found: [String] = []
        if let text = (view as? UITextView)?.text ?? (view as? UILabel)?.text, !text.isEmpty { found.append(text) }
        for sub in view.subviews where !sub.isHidden && sub.alpha > 0 { found += texts(in: sub) }
        return found
    }

    /// SwiftUI builds its accessibility tree only while accessibility automation is on (XCUITest turns it on;
    /// an in-process test does not), so a lookup through it finds nothing until this has run. Private API,
    /// test target only.
    private static let accessibilityAutomation: Bool = {
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW),
              let symbol = dlsym(handle, "_AXSSetAutomationEnabled") else { return false }
        typealias SetEnabled = @convention(c) (Int32) -> Void
        unsafeBitCast(symbol, to: SetEnabled.self)(1)
        return true
    }()

    /// The frames, in screen points, of every accessibility button below `element`, left to right. Locates
    /// controls that carry no label; the tap on them is still a real touch.
    static func buttonFrames(in element: NSObject) -> [CGRect] {
        _ = accessibilityAutomation
        var frames: [CGRect] = []
        func collect(_ element: NSObject) {
            if element.accessibilityTraits.contains(.button), !element.accessibilityFrame.isEmpty {
                frames.append(element.accessibilityFrame)
            }
            if let view = element as? UIView { view.subviews.forEach(collect) }
            (element.accessibilityElements as? [NSObject])?.forEach(collect)
        }
        collect(element)
        return frames.sorted { $0.minX < $1.minX }
    }

    /// The centre, in `window` coordinates, of the first text view or label showing `text`.
    static func center(ofText text: String, in window: UIWindow) -> CGPoint? {
        func find(_ view: UIView) -> UIView? {
            if ((view as? UITextView)?.text ?? (view as? UILabel)?.text) == text { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let view = find(window) else { return nil }
        return view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
    }

    static func dump(_ view: UIView, depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: depth)
        var line = "\(pad)\(type(of: view)) \(view.frame)\n"
        for sub in view.subviews { line += dump(sub, depth: depth + 1) }
        return line
    }
}
