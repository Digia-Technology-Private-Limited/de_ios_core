import Foundation
import Testing

/// Runs [test] step by step: look up, validate against the [contract], run
/// the handler, settle. The first failure ends the test with the file, name,
/// step and line. Mirrors `runner.dart`.
///
/// A hung file ends at 2 minutes (the Flutter driver's per-file backstop):
/// the steps race a 120 s timer, so a stuck step fails alone with a
/// "timed out" reason instead of blocking later tests.
@MainActor
func runYamlTest(
    _ test: YamlTestFile,
    yamlDir: URL,
    contract: YamlContract,
    handlers: [String: YamlHandler]
) async {
    await SdkGate.shared.enter()
    defer { Task { await SdkGate.shared.leave() } }
    do {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await runSteps(
                    test, yamlDir: yamlDir, contract: contract, handlers: handlers)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 120_000_000_000)
                throw YamlTestFailure(
                    "timed out after 120s with no step finishing")
            }
            try await group.next()
            group.cancelAll()
        }
    } catch {
        Issue.record(Comment(rawValue: describeYamlFailure(test.path, test.name, error)))
    }
}

@MainActor
private func runSteps(
    _ test: YamlTestFile,
    yamlDir: URL,
    contract: YamlContract,
    handlers: [String: YamlHandler]
) async {
    let world = YamlWorld(yamlDir: yamlDir)
    let stem = test.path.split(separator: "/").last.map(String.init) ?? test.path
    world.testStem = stem.hasSuffix(".yaml") ? String(stem.dropLast(5)) : stem
    defer { world.tearDown() }
    // `TEST_RUNNER_YAML_KEEP_GOING=1`: a failed step is recorded and the file
    // goes on, to see every failure of a file in one local run.
    let keepGoing = ProcessInfo.processInfo.environment["YAML_KEEP_GOING"] == "1"
    for (index, step) in test.steps.enumerated() {
        world.step = step
        do {
            let args = try contract.bind(step)
            guard let handler = handlers[step.name] else {
                throw YamlTestFailure(
                    "no handler registered for \"\(step.name)\"",
                    line: step.line)
            }
            try await handler(world, args)
            await world.settle()
        } catch is CancellationError {
            // The 120 s backstop won and already recorded the failure.
            return
        } catch {
            Issue.record(Comment(rawValue: describeYamlFailure(
                test.path, test.name, error,
                step: step, index: index + 1, total: test.steps.count)))
            if keepGoing { continue }
            return
        }
    }
    await world.finish()
}

/// The failure shape of proposal §5.5. [step] is absent for file-level
/// failures (header, syntax).
func describeYamlFailure(
    _ path: String, _ name: String?, _ error: Error,
    step: YamlStep? = nil, index: Int? = nil, total: Int? = nil
) -> String {
    let failure = error as? YamlTestFailure
    let detail = failure?.description ?? String(describing: error)
    let line = step?.line ?? failure?.line
    return ([
        "FAIL \(path)\(line.map { ":\($0)" } ?? "")",
        name.map { "  \"\($0)\"" },
        step.flatMap { s in index.flatMap { i in total.map { t in
            "  step \(i)/\(t) (line \(s.line)): \(s.written)"
        } } },
    ].compactMap { $0 }
        + detail.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix("  ") ? String($0) : "  \($0)" }
    ).joined(separator: "\n")
}
