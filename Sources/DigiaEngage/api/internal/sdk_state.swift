/// not initialized → initializing → ready / failed, as Flutter and Android.
///
/// `failed` means the campaign fetch failed; the host may call
/// `Digia.initialize()` again from there (SP4).
enum SDKState {
    case notInitialized
    case initializing
    case ready
    case failed
}
