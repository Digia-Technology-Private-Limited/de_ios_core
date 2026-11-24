import Foundation
import SwiftUI
import UIKit
@testable import DigiaEngage

/// Host-driven navigation through DigiaNavigationScreenObserver, without a
/// real navigation controller: view controllers carry the names a real app's
/// screens would, so the observer's extraction (restorationId else title else
/// type name) and forwarding run exactly as in production.
let yamlNavigationHandlers: [String: YamlHandler] = [
    "pushScreen": pushScreen,
    "replaceScreen": replaceScreen,
    "popScreen": popScreen,
    "showDialog": showDialog,
    "pushCover": pushCover,
    "popCover": popCover,
]

@MainActor private func navName(_ args: [String: Any], world: YamlWorld) throws -> (String?, String?) {
    let name = args["name"] as? String
    let title = args["title"] as? String
    if let n = name, !n.isEmpty, n.trimmingCharacters(in: .whitespaces).isEmpty {
        throw YamlTestFailure(
            "pushScreen name must not be blank",
            expected: "a non-empty name or title",
            line: world.step.line)
    }
    let rid: String? = (name?.isEmpty == true) ? nil : name
    let t: String? = (title?.isEmpty == true) ? nil : title
    // Both nil means a typeless screen: iOS reports its type name.
    return (rid, t)
}

@MainActor private func makeScreenVC(restorationId: String?, title: String?) -> UIViewController {
    if restorationId == nil && title == nil {
        return YamlPlainScreen()
    }
    let vc = UIViewController()
    vc.restorationIdentifier = restorationId
    vc.title = title
    return vc
}

private final class YamlPlainScreen: UIViewController {}

@MainActor private func pushScreen(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    let (rid, t) = try navName(args, world: world)
    let vc = makeScreenVC(restorationId: rid, title: t)
    world.navStack.append(YamlNavEntry(viewController: vc, isDialog: false))
    let observer = DigiaNavigationScreenObserver()
    let nav = UINavigationController()
    observer.navigationController(nav, didShow: vc, animated: false)
    await world.settle()
}

@MainActor private func replaceScreen(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    let (rid, t) = try navName(args, world: world)
    let vc = makeScreenVC(restorationId: rid, title: t)
    if !world.navStack.isEmpty { world.navStack.removeLast() }
    world.navStack.append(YamlNavEntry(viewController: vc, isDialog: false))
    let observer = DigiaNavigationScreenObserver()
    let nav = UINavigationController()
    observer.navigationController(nav, didShow: vc, animated: false)
    await world.settle()
}

@MainActor private func popScreen(_ world: YamlWorld, _ args: [String: Any]) async throws {
    _ = try world.sdk
    guard !world.navStack.isEmpty else {
        throw YamlTestFailure(
            "nothing to pop",
            expected: "a pushScreen or showDialog before this step",
            line: world.step.line)
    }
    let popped = world.navStack.removeLast()
    if popped.isDialog {
        await world.settle()
        return
    }
    if let revealed = world.navStack.last {
        if revealed.isDialog {
            await world.settle()
            return
        }
        let observer = DigiaNavigationScreenObserver()
        let nav = UINavigationController()
        observer.navigationController(nav, didShow: revealed.viewController, animated: false)
    } else {
        Digia.setCurrentScreen(name: "")
    }
    await world.settle()
}

@MainActor private func showDialog(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let vc = UIViewController()
    world.navStack.append(YamlNavEntry(viewController: vc, isDialog: true))
}

/// Covers the app with a real full-screen "Cover", as an app opening its cart
/// would: the slot's view leaves the window, so a playing canvas video pauses,
/// without changing the reported screen. Dismissed with popCover.
@MainActor private func pushCover(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let window = world.window else {
        throw YamlTestFailure(
            "nothing to cover",
            expected: "launchApp before this command",
            line: world.step.line)
    }
    guard world.coverPresented == nil else {
        throw YamlTestFailure(
            "a cover is already up",
            expected: "popCover before pushing another",
            line: world.step.line)
    }
    let vc = UIHostingController(rootView: coverScreen())
    vc.modalPresentationStyle = .fullScreen
    window.rootViewController?.present(vc, animated: false)
    world.coverPresented = vc
    await world.settle()
}

@MainActor private func coverScreen() -> some View {
    Text("Cover")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .foregroundColor(.white)
}

/// Takes the pushCover screen away again, uncovering the app.
@MainActor private func popCover(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let presented = world.coverPresented else {
        throw YamlTestFailure(
            "nothing to uncover",
            expected: "a pushCover before this step",
            actual: "no cover is up",
            line: world.step.line)
    }
    world.coverPresented = nil
    presented.dismiss(animated: false)
    await world.settle()
}
