import Foundation

/// iOS mirror of Android's `DiagnosticsReporter`: turns a plugin
/// ``DiagnosticReport`` into a single gated log line when the plugin is
/// unhealthy, so every health-check site reports in an identical format.
struct DiagnosticsReporter: Sendable {
    let logger: @Sendable (String) -> Void

    func report(_ report: DiagnosticReport, source: String) {
        guard !report.isHealthy else { return }
        logger(
            "[\(source)] unhealthy: \(report.issue ?? "unknown"); "
                + "resolution=\(report.resolution ?? "n/a")"
        )
    }

    func reportWarning(_ message: String) {
        logger(message)
    }

    func reportHealthEvent(_ eventType: String, params: [String: String]) {
        logger("[HealthEvent] type=\(eventType) params=\(params)")
    }
}
