import SwiftUI

@MainActor
public struct DigiaScreen: View {
    private let name: String

    public init(_ name: String) {
        self.name = name
    }

    public var body: some View {
        EmptyView()
    }
}
