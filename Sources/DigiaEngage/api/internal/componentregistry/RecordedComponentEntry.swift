import Foundation

/// One page/anchor/slot key recorded so far this process — what
/// `DigiaRecordedSessionScreen` lists. Mirrors the shape sent to
/// `recordComponents`, minus `platform` (implied — this list is always the
/// current device's own recordings).
struct RecordedComponentEntry: Identifiable {
    let id = UUID()
    let type: String
    let key: String
    let screenName: String?
}
