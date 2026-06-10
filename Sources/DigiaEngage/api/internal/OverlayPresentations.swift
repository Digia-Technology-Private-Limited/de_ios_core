import SwiftUI

struct DigiaViewPresentation: Equatable, Sendable {
    let viewID: String
    let title: String?
    let text: String?
    let args: [String: JSONValue]
}

struct DigiaToastPresentation: Equatable, Sendable {
    let message: String
    let durationSeconds: Double
}


