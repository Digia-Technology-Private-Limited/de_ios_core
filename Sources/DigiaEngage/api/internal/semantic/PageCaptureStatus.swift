import Foundation

struct PageCaptureStatus: Equatable {
    let state: String
    let message: String?

    init(state: String = "idle", message: String? = nil) {
        self.state = state
        self.message = message
    }
}
