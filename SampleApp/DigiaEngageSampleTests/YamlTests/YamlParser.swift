import Foundation
import Yams

/// One command of a test file: its name, the argument exactly as written
/// (`${VAR}` already substituted), and where it sits in the file.
/// Mirrors `flutter/core-yaml-poc/test/yaml/parser.dart`.
struct YamlStep: @unchecked Sendable {
    /// The command name.
    let name: String

    /// `nil` (bare), a scalar (shorthand for the command's main key) or a map.
    let rawArg: Any?

    /// 1-based line of the step in the YAML file.
    let line: Int

    /// The step's source text, for failure output.
    let written: String
}

struct YamlTestFile: @unchecked Sendable {
    /// Path used in failure output, relative to the Test Kit root.
    let path: String
    let name: String
    let tags: [String]

    /// The reason `skip.ios` gives, or nil when the test runs here.
    let skipIos: String?
    let steps: [YamlStep]
}

private let headerKeys: Set<String> = ["name", "tags", "env", "appId", "skip"]
private let stacks = ["flutter", "android", "ios"]

/// Parses [source]: a header document, `---`, a command list. Throws
/// [YamlTestFailure] (with the line) on anything malformed.
func parseYamlTest(_ source: String, path: String) throws -> YamlTestFile {
    let docs: [Node]
    do {
        var sequence = try compose_all(yaml: source)
        var out: [Node] = []
        while let doc = sequence.next() {
            out.append(doc)
        }
        if let error = sequence.error {
            throw error
        }
        docs = out
    } catch {
        throw YamlTestFailure("YAML syntax error: \(error)", line: 1)
    }
    guard docs.count == 2,
          case .mapping(let header) = docs[0],
          case .sequence(let commands) = docs[1]
    else {
        throw YamlTestFailure(
            "malformed test file",
            expected: "a header map, a `---` line, then a list of commands",
            actual: "\(docs.count) YAML document(s)",
            line: 1)
    }
    try checkHeaderKeys(header)
    let sourceLines = source.components(separatedBy: "\n")

    guard case .scalar(let nameScalar) = header["name"],
          let name = plainScalar(nameScalar) as? String,
          !name.trimmingCharacters(in: .whitespaces).isEmpty
    else {
        throw YamlTestFailure(
            "header `name` is required",
            expected: "a non-empty string",
            actual: header["name"].map { String(describing: plainNode($0)) } ?? "missing",
            line: header.mark?.line ?? 1)
    }
    let env = try readEnv(header)
    let tags: [String]
    if let tagsNode = header["tags"] {
        guard case .sequence(let seq) = tagsNode else {
            throw YamlTestFailure("header `tags` must be a list", line: tagsNode.mark?.line)
        }
        tags = seq.map { "\((plainNode($0) as? String) ?? String(describing: plainNode($0)))" }
    } else {
        tags = []
    }
    let commandNodes = Array(commands)
    let steps = try commandNodes.enumerated().map { index, node in
        try makeStep(
            node, env: env, sourceLines: sourceLines,
            nextStartLine: index + 1 < commandNodes.count
                ? commandNodes[index + 1].mark?.line : nil)
    }
    return YamlTestFile(
        path: path, name: name, tags: tags,
        skipIos: try skipReason(header), steps: steps)
}

private func checkHeaderKeys(_ header: Node.Mapping) throws {
    for (key, _) in header {
        guard case .scalar(let scalar) = key else {
            throw YamlTestFailure(
                "unknown header key \(key)",
                expected: "one of \(headerKeys.sorted())",
                line: key.mark?.line)
        }
        let name = plainScalar(scalar) as? String ?? scalar.string
        if !headerKeys.contains(name) {
            throw YamlTestFailure(
                "unknown header key \"\(name)\"",
                expected: "one of \(headerKeys.sorted())",
                line: key.mark?.line)
        }
    }
}

private func readEnv(_ header: Node.Mapping) throws -> [String: String] {
    guard let raw = header["env"] else { return [:] }
    guard case .mapping(let env) = raw else {
        throw YamlTestFailure("header `env` must be a map", line: raw.mark?.line)
    }
    var out: [String: String] = [:]
    for (key, value) in env {
        guard case .scalar(let keyScalar) = key,
              let name = plainScalar(keyScalar) as? String
        else {
            throw YamlTestFailure("header `env` keys must be strings", line: key.mark?.line)
        }
        let plain = plainNode(value)
        out[name] = (plain as? String) ?? String(describing: plain as Any)
    }
    return out
}

private func skipReason(_ header: Node.Mapping) throws -> String? {
    guard let skip = header["skip"] else { return nil }
    guard case .mapping(let map) = skip else {
        throw YamlTestFailure(
            "header `skip` must be a map of stack to reason",
            line: skip.mark?.line)
    }
    var ios: String?
    for (key, value) in map {
        guard case .scalar(let keyScalar) = key,
              let name = plainScalar(keyScalar) as? String
        else {
            throw YamlTestFailure("`skip` keys must be stack names", line: key.mark?.line)
        }
        if !stacks.contains(name) {
            throw YamlTestFailure(
                "unknown `skip` key \"\(name)\"",
                expected: "one of \(stacks)",
                line: key.mark?.line)
        }
        guard let reason = plainNode(value) as? String,
              !reason.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw YamlTestFailure(
                "`skip.\(name)` needs a reason",
                expected: "a non-empty string",
                line: value.mark?.line)
        }
        if name == "ios" { ios = reason }
    }
    return ios
}

private func makeStep(
    _ node: Node, env: [String: String], sourceLines: [String], nextStartLine: Int?
) throws -> YamlStep {
    let line = node.mark?.line ?? 1
    let endLine = (nextStartLine ?? sourceLines.count + 1) - 1
    let written: String = {
        guard line >= 1, endLine >= line else { return "" }
        let slice = sourceLines[(line - 1)..<min(endLine, sourceLines.count)]
        // A step's own lines, without trailing blank lines that separate steps.
        var lines = Array(slice)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }()
    if case .scalar(let scalar) = node,
       let name = plainScalar(scalar) as? String
    {
        return YamlStep(name: name, rawArg: nil, line: line, written: written)
    }
    if case .mapping(let map) = node, map.count == 1,
       let (key, value) = map.first,
       case .scalar(let keyScalar) = key,
       let name = plainScalar(keyScalar) as? String
    {
        return YamlStep(
            name: name,
            rawArg: try substitute(plainNode(value), env: env, line: line),
            line: line, written: written)
    }
    throw YamlTestFailure(
        "malformed step",
        expected: "a bare command name or a map with exactly one command key",
        actual: written,
        line: line)
}

/// A Yams node as plain Swift values: dictionaries, arrays and scalars.
func plainNode(_ node: Node) -> Any? {
    switch node {
    case .scalar(let scalar):
        return plainScalar(scalar)
    case .mapping(let map):
        var out: [String: Any] = [:]
        for (key, value) in map {
            if case .scalar(let keyScalar) = key,
               let name = plainScalar(keyScalar) as? String
            {
                out[name] = plainNode(value) ?? NSNull()
            } else {
                out[String(describing: plainNode(key) ?? NSNull())] = plainNode(value) ?? NSNull()
            }
        }
        return out
    case .sequence(let seq):
        return seq.map { plainNode($0) ?? NSNull() }
    case .alias:
        return nil
    }
}

private func plainScalar(_ scalar: Node.Scalar) -> Any? {
    switch scalar.style {
    case .singleQuoted, .doubleQuoted:
        return scalar.string
    default:
        break
    }
    // Unquoted scalars, by the YAML 1.2 core schema the Flutter driver
    // (`package:yaml`) also reads: only true/false are booleans, timestamps
    // and yes/no stay strings.
    let string = scalar.string
    switch string {
    case "", "null", "Null", "NULL", "~":
        return nil
    case "true", "True", "TRUE":
        return true
    case "false", "False", "FALSE":
        return false
    default:
        break
    }
    if let int = Int(string) {
        return int
    }
    if let double = Double(string), string.contains(".") || string.contains("e")
        || string.contains("E")
    {
        return double
    }
    return string
}

private let variablePattern = try! NSRegularExpression(pattern: #"\$\{(\w+)\}"#)

private func substitute(_ value: Any?, env: [String: String], line: Int) throws -> Any? {
    if let text = value as? String {
        var result = text
        let matches = variablePattern.matches(
            in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard let whole = Range(match.range(at: 0), in: text),
                  let nameRange = Range(match.range(at: 1), in: text)
            else { continue }
            let name = String(text[nameRange])
            guard let replacement = env[name] else {
                throw YamlTestFailure(
                    "undefined variable \"\(name)\"",
                    expected: "a key under header `env`",
                    line: line)
            }
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }
    if var map = value as? [String: Any] {
        for key in map.keys {
            map[key] = try substitute(map[key], env: env, line: line) ?? NSNull()
        }
        return map
    }
    if let list = value as? [Any] {
        return try list.map { try substitute($0, env: env, line: line) ?? NSNull() }
    }
    return value
}
