import Foundation
import Testing

/// One discovered YAML file. The display name is the path relative to the
/// Test Kit root, so every file is its own test case.
struct YamlCase: Sendable, CustomStringConvertible {
    /// The YAML file on disk.
    let file: URL
    /// Path relative to `testkit/sdk-tests/`, used in failure output.
    let path: String
    let parsed: YamlTestFile?
    let parseError: YamlTestFailure?

    var description: String { path }
    var skipIos: String? { parsed?.skipIos }
}

/// Finds `testkit/sdk-tests/` from the test source, the same way the
/// existing tests find `testkit/` and goldens: an SPM test target cannot
/// list resources outside the package, but it can walk up from `#filePath`.
enum YamlDiscovery {
    static func root(file: StaticString = #filePath) -> URL? {
        FixtureLoader.workspaceURL(file: file)?
            .appendingPathComponent("testkit/sdk-tests")
    }

    /// Every `tests/**/*.yaml`, sorted, as cases. Missing Test Kit means no
    /// cases; [testkitPresent] reports that instead of running zero tests.
    static func cases(file: StaticString = #filePath) -> [YamlCase] {
        guard let root = root(file: file) else { return [] }
        let tests = root.appendingPathComponent("tests")
        guard let enumerator = FileManager.default.enumerator(
            at: tests, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        var out: [YamlCase] = []
        for case let url as URL in enumerator where url.pathExtension == "yaml" {
            let path = "tests/" + String(url.path.dropFirst(tests.path.count + 1))
            let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            do {
                let parsed = try parseYamlTest(source, path: path)
                out.append(YamlCase(file: url, path: path, parsed: parsed, parseError: nil))
            } catch let failure as YamlTestFailure {
                out.append(YamlCase(file: url, path: path, parsed: nil, parseError: failure))
            } catch {
                out.append(YamlCase(
                    file: url, path: path, parsed: nil,
                    parseError: YamlTestFailure("could not read file: \(error)", line: 1)))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Files that run on iOS: everything without `skip.ios`.
    /// `TEST_RUNNER_YAML_FILTER=survey/sv0,dmc/c0` (xcodebuild forwards it as
    /// `YAML_FILTER`) runs only the files whose path contains one of the
    /// comma-separated parts, while iterating locally; unset runs every file.
    /// `TEST_RUNNER_YAML_SHARD=0/3` (forwarded as `YAML_SHARD`) runs only shard
    /// 0 of 3 (interleaved by sorted index) for parallel simulator runs.
    static func runnable(file: StaticString = #filePath) -> [YamlCase] {
        let env = ProcessInfo.processInfo.environment
        let parts = (env["YAML_FILTER"] ?? "")
            .split(separator: ",").map(String.init)
        let filtered = cases(file: file).filter { test in
            test.skipIos == nil && (parts.isEmpty || parts.contains { test.path.contains($0) })
        }
        guard let shardSpec = env["YAML_SHARD"],
              case let pieces = shardSpec.split(separator: "/"),
              pieces.count == 2,
              let shardIndex = Int(pieces[0]),
              let shardCount = Int(pieces[1]),
              shardCount > 1,
              (0..<shardCount).contains(shardIndex)
        else { return filtered }
        // Balance heavy files (many steps / goldens / real-time holds) evenly across
        // shards using greedy LPT scheduling, then restore path order within each shard.
        func weight(_ c: YamlCase) -> Int {
            var w = max(1, c.parsed?.steps.count ?? 1)
            if c.path.contains("hold") { w += 120 }
            if c.path.contains("sv16_operators_numbers") { w += 100 }
            if c.path.contains("f32_floater_goldens") || c.path.contains("f33_pip_goldens") { w += 80 }
            return w
        }
        let weighted = filtered.sorted { a, b in
            let wa = weight(a), wb = weight(b)
            return wa != wb ? wa > wb : a.path < b.path
        }
        var buckets = Array(repeating: [YamlCase](), count: shardCount)
        var loads = Array(repeating: 0, count: shardCount)
        for test in weighted {
            let target = loads.enumerated().min(by: { $0.element < $1.element })?.offset ?? 0
            buckets[target].append(test)
            loads[target] += weight(test)
        }
        return buckets[shardIndex].sorted { $0.path < $1.path }
    }

    /// Files `skip.ios` marks as skipped, each with its reason in the header.
    static func skipped(file: StaticString = #filePath) -> [YamlCase] {
        cases(file: file).filter { $0.skipIos != nil }
    }

    static func contract(file: StaticString = #filePath) throws -> YamlContract {
        guard let root = root(file: file) else {
            throw YamlTestFailure("Test Kit sdk-tests not found; run `bash clone.sh` in de_workspace")
        }
        return try YamlContract.load(from: root.appendingPathComponent("commands.yaml"))
    }
}

/// Runs every `<workspace>/testkit/sdk-tests/tests/**/*.yaml` as its own test
/// against the real SDK and real UI. Format: `ai_docs/sdk-yaml-tests-proposal.md`
/// §3; commands: `testkit/sdk-tests/commands.yaml`.
@Suite("YAML SDK tests", .serialized, .tags(.integration, .yaml))
struct YamlSdkTests {
    @Test("the Test Kit sdk-tests are checked out")
    func testkitPresent() throws {
        if YamlDiscovery.root() == nil {
            Issue.record(
                "Test Kit sdk-tests not found beside this repo; run `bash clone.sh` in de_workspace")
        }
    }

    @Test("driver handlers equal the contract commands", .tags(.contract))
    func contractEquals() throws {
        let contract = try YamlDiscovery.contract()
        let handlerNames = Set(yamlAllHandlers.keys)
        let contractNames = Set(contract.commands.keys)
        let missing = contractNames.subtracting(handlerNames).sorted()
        let extra = handlerNames.subtracting(contractNames).sorted()
        if !missing.isEmpty || !extra.isEmpty {
            Issue.record(Comment(rawValue:
                "in commands.yaml but no handler: \(missing); " +
                "handler but not in commands.yaml: \(extra)"))
        }
    }

    /// A stuck step fails alone with a "timed out" reason and never blocks
    /// later tests: every wait the driver does is bounded (5-10 s), and this
    /// backstop ends a hung test file at 2 minutes, like the Flutter driver's
    /// per-file timeout. (Swift Testing's `.timeLimit` needs iOS 16+, but the
    /// package targets iOS 15, so the race below does the same job.)
    @Test("runs the shared YAML file", arguments: YamlDiscovery.runnable())
    func yamlFileRuns(_ file: YamlCase) async {
        if let failure = file.parseError {
            Issue.record(Comment(rawValue: describeYamlFailure(file.path, nil, failure)))
            return
        }
        guard let parsed = file.parsed else {
            Issue.record(Comment(rawValue: describeYamlFailure(
                file.path, nil,
                YamlTestFailure("could not parse file", line: 1))))
            return
        }
        do {
            let contract = try YamlDiscovery.contract()
            await runYamlTest(
                parsed, yamlDir: file.file.deletingLastPathComponent(),
                contract: contract, handlers: yamlAllHandlers)
        } catch {
            Issue.record(Comment(rawValue: describeYamlFailure(file.path, parsed.name, error)))
        }
    }

    /// A file with `skip.ios` shows as its own skipped test, named by path;
    /// its reason is in the file header. (Swift Testing has no per-argument
    /// skip with a reason: `XCTSkip` reports as passed here, so the skipped
    /// set runs disabled instead.)
    @Test(
        "is skipped on ios (see the file's skip.ios reason)",
        .disabled("this file sets skip.ios; the reason is in its header"),
        arguments: YamlDiscovery.skipped())
    func yamlFileSkipped(_ file: YamlCase) async {}
}
