import Foundation
import SwiftUI

/// A typed navigation entry carrying page identity and page-level arguments.
struct NavigationEntry: Hashable, Sendable {
    let id: UUID
    let pageID: String

    init(pageID: String) {
        self.id = UUID()
        self.pageID = pageID
    }
}

@MainActor
final class DigiaNavigationController: ObservableObject {
    @Published private(set) var rootRoute: String?
    @Published private(set) var rootArgs: [String: JSONValue] = [:]
    @Published private(set) var path: [NavigationEntry] = []
    @Published var allowsSwipeBack: Bool = true

    /// Args keyed by entry UUID, stored separately to keep NavigationEntry lightweight.
    private var entryArgs: [UUID: [String: JSONValue]] = [:]
    /// Continuations awaiting a page result, keyed by the entry that was pushed.
    private var resultContinuations: [UUID: CheckedContinuation<JSONValue?, Never>] = [:]

    private static let pushAnimation = Animation.easeInOut(duration: 0.3)
    private static let popAnimation = Animation.easeInOut(duration: 0.25)

    // MARK: - Setup

    func setInitialRoute(_ route: String) {
        guard rootRoute == nil else { return }
        rootRoute = route
        path = []
    }

    func replaceStack(with route: String, args: [String: JSONValue] = [:]) {
        cleanUpAllContinuations()
        rootRoute = route
        rootArgs = args
        withAnimation(.easeInOut(duration: 0.25)) {
            path = []
        }
        entryArgs.removeAll()
    }

    func reset() {
        cleanUpAllContinuations()
        rootRoute = nil
        rootArgs = [:]
        path = []
        entryArgs.removeAll()
    }

    // MARK: - Path binding (swipe-back / system pop)
    // Called by the NavigationStack binding — UIKit is already animating, no withAnimation needed.

    func syncForPathChange(oldPath: [NavigationEntry], newPath: [NavigationEntry]) {
        if newPath.count < oldPath.count {
            let removedEntries = oldPath[newPath.count...]
            for entry in removedEntries {
                entryArgs.removeValue(forKey: entry.id)
                resultContinuations.removeValue(forKey: entry.id)?.resume(returning: nil)
            }
        }
        if path != newPath {
            path = newPath
        }
    }

    func updatePath(_ newPath: [NavigationEntry]) {
        syncForPathChange(oldPath: path, newPath: newPath)
    }

    // MARK: - Push (fire-and-forget)

    func push(_ pageID: String, args: [String: JSONValue] = [:]) {
        let normalized = NavigationUtil.normalizedRoute(pageID)
        guard !normalized.isEmpty else { return }
        if currentPageID == normalized { return }
        if rootRoute == nil {
            rootRoute = normalized
            rootArgs = args
            return
        }
        let entry = NavigationEntry(pageID: normalized)
        entryArgs[entry.id] = args
        withAnimation(Self.pushAnimation) {
            path.append(entry)
        }
    }

    // MARK: - Push (await result)

    /// Pushes a page and suspends until it is popped. The result value is whatever
    /// was passed to `pop(result:)` by the navigateBack action, or `nil` on swipe-back.
    func push(_ pageID: String, args: [String: JSONValue] = [:], waitingForResult: Bool) async
        -> JSONValue?
    {
        let normalized = NavigationUtil.normalizedRoute(pageID)
        guard !normalized.isEmpty else { return nil }
        if rootRoute == nil {
            rootRoute = normalized
            rootArgs = args
            return nil
        }
        let entry = NavigationEntry(pageID: normalized)
        entryArgs[entry.id] = args
        withAnimation(Self.pushAnimation) {
            path.append(entry)
        }
        guard waitingForResult else { return nil }
        return await withCheckedContinuation { [entryID = entry.id] continuation in
            resultContinuations[entryID] = continuation
        }
    }

    // MARK: - Pop

    func pop(result: JSONValue? = nil) {
        guard !path.isEmpty else { return }
        let entry = path.last!
        _ = withAnimation(Self.popAnimation) { path.removeLast() }
        entryArgs.removeValue(forKey: entry.id)
        resultContinuations.removeValue(forKey: entry.id)?.resume(returning: result)
    }

    func popUntil(_ matcher: (String) -> Bool) {
        withAnimation(Self.popAnimation) {
            while !path.isEmpty, let last = path.last, !matcher(last.pageID) {
                let entry = path.removeLast()
                entryArgs.removeValue(forKey: entry.id)
                resultContinuations.removeValue(forKey: entry.id)?.resume(returning: nil)
            }
        }
    }

    // MARK: - Accessors

    func args(for entryID: UUID) -> [String: JSONValue] {
        entryArgs[entryID] ?? [:]
    }

    var currentPageID: String? {
        path.last?.pageID ?? rootRoute
    }

    // MARK: - Private

    private func cleanUpAllContinuations() {
        for entry in path {
            resultContinuations.removeValue(forKey: entry.id)?.resume(returning: nil)
        }
    }
}
