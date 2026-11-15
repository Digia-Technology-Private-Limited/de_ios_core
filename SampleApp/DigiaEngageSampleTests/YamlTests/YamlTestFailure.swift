/// A failure the driver reports in its own shape: what was expected, what
/// was found. Thrown by the parser, the contract check and handlers; the
/// runner adds the file, test name, step and source line (proposal §5.5).
/// Mirrors `flutter/core-yaml-poc/test/yaml/failure.dart`.
struct YamlTestFailure: Error, CustomStringConvertible, @unchecked Sendable {
    init(_ message: String, expected: String? = nil, actual: String? = nil, line: Int? = nil) {
        self.message = message
        self.expected = expected
        self.actual = actual
        self.line = line
    }

    let message: String
    let expected: String?
    let actual: String?

    /// 1-based line in the YAML file, when the failure knows it.
    let line: Int?

    var description: String {
        ([message]
            + (expected.map { ["  expected: \($0)"] } ?? [])
            + (actual.map { ["  actual:   \($0)"] } ?? [])
        ).joined(separator: "\n")
    }
}
