/// Merges the per-area handler maps. A name defined twice is a bug in the
/// handler files, so it fails instead of letting one silently win.
/// Mirrors `registry.dart`.
func mergeYamlHandlers(_ areas: [[String: YamlHandler]]) -> [String: YamlHandler] {
    var merged: [String: YamlHandler] = [:]
    for area in areas {
        for (name, handler) in area {
            precondition(
                merged[name] == nil,
                "command \"\(name)\" is registered by two handler files")
            merged[name] = handler
        }
    }
    return merged
}

/// A handler for a command the contract lists but this stack cannot
/// implement. The set stays equal to the contract (proposal §6.3); a test
/// that reaches it fails with the reason, so it reads as a parity gap
/// instead of a missing handler.
func unsupported(_ reason: String) -> YamlHandler {
    { world, _ in
        throw YamlTestFailure("unsupported on ios: \(reason)", line: world.step.line)
    }
}
