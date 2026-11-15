import Foundation
import Yams

/// A duration argument, in milliseconds. A bare number is milliseconds.
/// Mirrors the `duration` coercion in `contract.dart`.
struct YamlDuration {
    let milliseconds: Int64
}

/// The contract, loaded from `commands.yaml`: the one list of commands, their
/// main key and typed arguments. Mirrors `contract.dart`.
struct YamlContract {
    let commands: [String: YamlCommandSpec]

    static func load(from file: URL) throws -> YamlContract {
        let source = try String(contentsOf: file, encoding: .utf8)
        guard let doc = try Yams.load(yaml: source) as? [String: Any],
              let list = doc["commands"] as? [[String: Any]]
        else {
            throw YamlTestFailure("commands.yaml has no commands list", line: 1)
        }
        var commands: [String: YamlCommandSpec] = [:]
        for entry in list {
            guard let name = entry["name"] as? String else { continue }
            commands[name] = YamlCommandSpec(
                name: name,
                main: entry["main"] as? String,
                args: entry["args"] as? [String: String] ?? [:],
                required: entry["required"] as? [String] ?? [])
        }
        return YamlContract(commands: commands)
    }

    /// [step]'s arguments as a plain map, checked against its command's spec
    /// and coerced to the declared types.
    func bind(_ step: YamlStep) throws -> [String: Any] {
        guard let spec = commands[step.name] else {
            throw YamlTestFailure(
                "unknown command \"\(step.name)\"",
                expected: "a command listed in commands.yaml",
                line: step.line)
        }
        return try spec.bind(step)
    }
}

struct YamlCommandSpec {
    let name: String
    let main: String?

    /// Argument name to type: string|int|bool|map|list|json|duration.
    let args: [String: String]
    let required: [String]

    func bind(_ step: YamlStep) throws -> [String: Any] {
        let raw = step.rawArg
        let given: [String: Any]
        if let map = raw as? [String: Any] {
            given = map
        } else if raw == nil {
            given = [:]
        } else if raw is [Any] {
            throw fail(step, "argument must be a scalar or a map")
        } else if main == nil {
            throw fail(step, "takes no scalar argument",
                       expected: "a map or nothing")
        } else {
            given = [main!: raw!]
        }

        for key in given.keys {
            if args[key] == nil {
                throw fail(step, "unknown argument \"\(key)\"",
                           expected: "one of \(args.keys.sorted())")
            }
        }
        for key in required {
            if given[key] == nil {
                throw fail(step, "missing required argument \"\(key)\"")
            }
        }
        var out: [String: Any] = [:]
        for (key, value) in given {
            out[key] = try coerce(step: step, key: key, value: value)
        }
        return out
    }

    private func coerce(step: YamlStep, key: String, value: Any) throws -> Any {
        let type = args[key]!
        let ok: Bool = switch type {
        case "string": value is String
        case "int": value is Int
        case "bool": value is Bool
        case "map": value is [String: Any]
        case "list": value is [Any]
        case "json": true
        case "duration": (value is String && YamlCommandSpec.durationPattern
            .firstMatch(in: value as! String, range: NSRange(
                (value as! String).startIndex..., in: value as! String)) != nil) || value is Int
        default: false
        }
        if type != "string", type != "int", type != "bool", type != "map",
           type != "list", type != "json", type != "duration"
        {
            throw YamlTestFailure("commands.yaml: \(name).\(key) has unknown type \(type)")
        }
        if !ok {
            throw fail(
                step, "argument \"\(key)\" has the wrong type",
                expected: type == "duration" ? "duration like 500ms, 2s, 1m, 1h, 2d" : type,
                actual: "\(Swift.type(of: value)): \(value)")
        }
        if type == "duration" {
            if let ms = value as? Int { return YamlDuration(milliseconds: Int64(ms)) }
            return YamlDuration(milliseconds: parseDuration(value as! String))
        }
        return value
    }

    private func fail(_ step: YamlStep, _ message: String, expected: String? = nil,
                      actual: String? = nil) -> YamlTestFailure
    {
        YamlTestFailure("\(name): \(message)", expected: expected, actual: actual, line: step.line)
    }

    private static let durationPattern = try! NSRegularExpression(pattern: #"^\d+(ms|s|m|h|d)$"#)

    private func parseDuration(_ text: String) -> Int64 {
        let number: Int64
        let unit: Character
        if text.hasSuffix("ms") {
            number = Int64(text.dropLast(2)) ?? 0
            unit = "x"
        } else {
            number = Int64(text.dropLast(1)) ?? 0
            unit = text.last ?? "s"
        }
        switch unit {
        case "x": return number
        case "s": return number * 1_000
        case "m": return number * 60_000
        case "h": return number * 3_600_000
        default: return number * 86_400_000
        }
    }
}
