import AppKit
import Foundation
import LitheCoreContracts
import LitheGoSupportModule
import LitheRustSupportModule
import Testing
@testable import Lithe

@Suite("P1-C inline rename, refactor this, and Go/Rust/Python runnable gutter")
struct InlineRenameAndRunnableGutterP1CTests {
    @Test
    func discoversGoMainTestsBenchmarksExamplesAndExcludesTestMain() {
        let mainURL = URL(fileURLWithPath: "/tmp/demo/cmd/server/main.go")
        let mainSource = """
        package main

        func main() {}
        func (s *Server) main() {}
        """
        let mainRunnables = DocumentRunnableDiscovery.discover(in: mainSource, url: mainURL)
        #expect(mainRunnables.count == 1)
        #expect(mainRunnables[0].kind == .application)
        #expect(mainRunnables[0].displayName == "server")
        #expect(mainRunnables[0].line == 3)

        let testURL = URL(fileURLWithPath: "/tmp/demo/calc_test.go")
        let testSource = """
        package demo

        import "testing"

        func TestMain(m *testing.M) {}
        func TestAdd(t *testing.T) {}
        func BenchmarkAdd(b *testing.B) {}
        func ExampleAdd() {}
        func helper(t *testing.T) {}
        """
        let testRunnables = DocumentRunnableDiscovery.discover(in: testSource, url: testURL)
        #expect(testRunnables.map(\.displayName) == ["TestAdd", "BenchmarkAdd", "ExampleAdd"])
        #expect(testRunnables.map(\.kind) == [.test, .benchmark, .example])
        #expect(testRunnables.map(\.line) == [6, 7, 8])
    }

    @Test
    func discoversRustMainAsyncTestsAndBenchmarks() {
        let url = URL(fileURLWithPath: "/tmp/crate/src/main.rs")
        let source = """
        fn main() {}

        #[test]
        /// Verifies arithmetic
        #[should_panic]
        fn test_panic() {}

        #[tokio::test]
        async fn test_async_flow() {}

        #[bench]
        fn bench_fast() {}

        fn helper() {}
        """
        let runnables = DocumentRunnableDiscovery.discover(in: source, url: url)
        #expect(runnables.map(\.displayName) == ["crate", "test_panic", "test_async_flow", "bench_fast"])
        #expect(runnables.map(\.kind) == [.application, .test, .test, .benchmark])
        #expect(runnables.map(\.line) == [1, 6, 9, 12])

        // Unit tests inside `mod tests` and nested source files emit module-qualified paths for `--exact`.
        let nestedURL = URL(fileURLWithPath: "/tmp/crate/src/math/ops.rs")
        let nestedSource = """
        // mod fake {
        pub fn add(a: i32, b: i32) -> i32 { a + b }

        #[cfg(test)]
        mod tests {
            use super::*;
            const BRACE: &str = "}";

            #[test]
            fn adds_numbers() {
                assert_eq!(add(1, 2), 3);
            }

            mod inner {
                #[test]
                fn nested_case() {}
            }
        }
        """
        let nestedRunnables = DocumentRunnableDiscovery.discover(in: nestedSource, url: nestedURL)
        #expect(nestedRunnables.map(\.displayName) == [
            "math::ops::tests::adds_numbers",
            "math::ops::tests::inner::nested_case"
        ])

        // Integration test files under `tests/` keep their target-local name.
        let integrationURL = URL(fileURLWithPath: "/tmp/crate/tests/cli.rs")
        let integrationSource = "#[test]\nfn runs_cli() {}\n"
        let integrationRunnables = DocumentRunnableDiscovery.discover(in: integrationSource, url: integrationURL)
        #expect(integrationRunnables.map(\.displayName) == ["runs_cli"])
    }

    @Test
    func discoversPythonMainTopLevelAndClassTestMethods() {
        let url = URL(fileURLWithPath: "/tmp/pyapp/test_math.py")
        let source = """
        def test_add():
            assert 1 + 1 == 2

        async def test_async_op():
            pass

        class TestSuite:
            def test_multiply(self):
                assert 2 * 3 == 6

            def helper(self):
                pass

        if __name__ == "__main__":
            print("run")
        """
        let runnables = DocumentRunnableDiscovery.discover(in: source, url: url)
        #expect(runnables.map(\.displayName) == ["test_add", "test_async_op", "TestSuite::test_multiply", "test_math"])
        #expect(runnables.map(\.kind) == [.test, .test, .test, .application])
        #expect(runnables.map(\.line) == [1, 4, 8, 14])
    }

    @Test
    @MainActor
    func goExecutionCapabilityPlansBenchmarkFlagsForBenchmarkRunnables() throws {
        let capability = GoExecutionCapability(executionSession: StubGoExecutionSession())
        let plan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "BenchmarkAdd", relativeFilePath: "pkg/calc_test.go"),
            relativeProjectFilePaths: ["go.mod", "pkg/calc_test.go"]
        ))
        #expect(plan.launchPlan.arguments == [
            "test", "./pkg", "-run", "^$", "-bench", "^BenchmarkAdd$", "-benchmem"
        ])
    }

    @Test
    @MainActor
    func rustExecutionCapabilityQualifiesNestedUnitTestsAndTargetsBinOrIntegrationFiles() throws {
        let capability = RustExecutionCapability(executionSession: StubGoExecutionSession())
        let nestedPlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "adds_numbers", relativeFilePath: "src/math/ops.rs"),
            relativeProjectFilePaths: ["Cargo.toml", "src/math/ops.rs"]
        ))
        #expect(nestedPlan.launchPlan.arguments == ["test", "math::ops::adds_numbers", "--", "--exact", "--nocapture"])

        let qualifiedPlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "math::ops::tests::adds_numbers", relativeFilePath: "src/math/ops.rs"),
            relativeProjectFilePaths: ["Cargo.toml", "src/math/ops.rs"]
        ))
        #expect(qualifiedPlan.launchPlan.arguments == ["test", "math::ops::tests::adds_numbers", "--", "--exact", "--nocapture"])

        let binPlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "tests::smoke", relativeFilePath: "src/bin/worker.rs"),
            relativeProjectFilePaths: ["Cargo.toml", "src/bin/worker.rs"]
        ))
        #expect(binPlan.launchPlan.arguments == ["test", "--bin", "worker", "tests::smoke", "--", "--exact", "--nocapture"])

        // Cargo directory-style bin & integration test targets resolve the folder name, not `main`.
        let dirBinPlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "smoke", relativeFilePath: "src/bin/tool/main.rs"),
            relativeProjectFilePaths: ["Cargo.toml", "src/bin/tool/main.rs"]
        ))
        #expect(dirBinPlan.launchPlan.arguments == ["test", "--bin", "tool", "smoke", "--", "--exact", "--nocapture"])

        let dirBinHelperPlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "check", relativeFilePath: "src/bin/tool/helper.rs"),
            relativeProjectFilePaths: ["Cargo.toml", "src/bin/tool/main.rs", "src/bin/tool/helper.rs"]
        ))
        #expect(dirBinHelperPlan.launchPlan.arguments == ["test", "--bin", "tool", "helper::check", "--", "--exact", "--nocapture"])

        let dirIntegrationPlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "end_to_end", relativeFilePath: "tests/suite/main.rs"),
            relativeProjectFilePaths: ["Cargo.toml", "tests/suite/main.rs"]
        ))
        #expect(dirIntegrationPlan.launchPlan.arguments == ["test", "--test", "suite", "end_to_end", "--", "--exact", "--nocapture"])

        let dirIntegrationFilePlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .file(relativePath: "tests/suite/main.rs"),
            relativeProjectFilePaths: ["Cargo.toml", "tests/suite/main.rs"]
        ))
        #expect(dirIntegrationFilePlan.launchPlan.arguments == ["test", "--test", "suite"])

        // Shared helper without `tests/common/main.rs` must not invent a bogus `--test mod` target.
        let sharedHelperPlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "helper_case", relativeFilePath: "tests/common/mod.rs"),
            relativeProjectFilePaths: ["Cargo.toml", "tests/common/mod.rs", "tests/api.rs"]
        ))
        #expect(sharedHelperPlan.launchPlan.arguments == ["test", "helper_case", "--", "--exact", "--nocapture"])

        // Unit-test modules under `src/tests/...` must NOT be misclassified as `--test <stem>`.
        let srcTestsPlan = try capability.testPlan(for: LanguageTestExtensionRequest(
            scope: .testCase(identifier: "adds", relativeFilePath: "src/tests/arithmetic.rs"),
            relativeProjectFilePaths: ["Cargo.toml", "src/lib.rs", "src/tests/arithmetic.rs"]
        ))
        #expect(srcTestsPlan.launchPlan.arguments == ["test", "tests::arithmetic::adds", "--", "--exact", "--nocapture"])

        // Binary target helper files retain their module path beneath `src/bin/<target>/`.
        #expect(DocumentRunnableDiscovery.rustFileModulePath(for: URL(fileURLWithPath: "/repo/src/bin/worker.rs")) == [])
        #expect(DocumentRunnableDiscovery.rustFileModulePath(for: URL(fileURLWithPath: "/repo/src/bin/tool/main.rs")) == [])
        #expect(DocumentRunnableDiscovery.rustFileModulePath(for: URL(fileURLWithPath: "/repo/src/bin/tool/helpers.rs")) == ["helpers"])
        #expect(DocumentRunnableDiscovery.rustFileModulePath(for: URL(fileURLWithPath: "/repo/src/bin/tool/sub/mod.rs")) == ["sub"])
    }

    @Test
    func debugLaunchConfigurationResolverBuildsGoRustAndPythonTestDebugPlans() throws {
        let workspace = URL(fileURLWithPath: "/tmp/polyglot", isDirectory: true)
        let rustTestBinary = workspace.appendingPathComponent("target/debug/deps/crate-abc123")
        let resolver = DebugLaunchConfigurationResolver(fileExists: { $0 == rustTestBinary.standardizedFileURL })

        let goProvider = LanguageProviderDescriptor(
            id: "go",
            displayName: "Go",
            fileExtensions: ["go"],
            capabilities: [.debugAdapter],
            activationPolicy: .onDemand
        )
        let goConfig = try resolver.resolveLanguageTest(
            provider: goProvider,
            scope: .testCase(identifier: "TestAdd", fileURL: workspace.appendingPathComponent("pkg/calc_test.go")),
            workspaceURL: workspace,
            configurations: [],
            selectedConfiguration: nil,
            options: { _ in RunOptions() }
        )
        #expect(goConfig.arguments["mode"] == ToolingJSONValue.string("test"))
        #expect(goConfig.arguments["args"] == ToolingJSONValue.array([.string("-test.run"), .string("^TestAdd$")]))
        // Delve requires canonical symlink-resolved paths on macOS (`/tmp` -> `/private/tmp`).
        let expectedGoProgram = workspace.appendingPathComponent("pkg").resolvingSymlinksInPath().standardizedFileURL.path
        #expect(goConfig.arguments["program"] == ToolingJSONValue.string(expectedGoProgram))
        #expect(goConfig.arguments["cwd"] == ToolingJSONValue.string(expectedGoProgram))

        let pyProvider = LanguageProviderDescriptor(
            id: "python",
            displayName: "Python",
            fileExtensions: ["py"],
            capabilities: [.debugAdapter],
            activationPolicy: .onDemand
        )
        let pyConfig = try resolver.resolveLanguageTest(
            provider: pyProvider,
            scope: .testCase(identifier: "TestSuite::test_mul", fileURL: workspace.appendingPathComponent("tests/test_math.py")),
            workspaceURL: workspace,
            configurations: [],
            selectedConfiguration: nil,
            options: { _ in RunOptions() }
        )
        #expect(pyConfig.arguments["module"] == ToolingJSONValue.string("pytest"))
        #expect(pyConfig.arguments["args"] == ToolingJSONValue.array([.string("tests/test_math.py::TestSuite::test_mul"), .string("-s")]))

        let rustProvider = LanguageProviderDescriptor(
            id: "rust",
            displayName: "Rust",
            fileExtensions: ["rs"],
            capabilities: [.debugAdapter],
            activationPolicy: .onDemand
        )
        let rustConfig = try resolver.resolveLanguageTest(
            provider: rustProvider,
            scope: .testCase(identifier: "tests::adds_numbers", fileURL: workspace.appendingPathComponent("src/lib.rs")),
            workspaceURL: workspace,
            configurations: [],
            selectedConfiguration: nil,
            preBuiltRustTestExecutableURL: rustTestBinary,
            options: { _ in RunOptions() }
        )
        #expect(rustConfig.arguments["program"] == ToolingJSONValue.string(rustTestBinary.standardizedFileURL.path))
        #expect(rustConfig.arguments["args"] == ToolingJSONValue.array([.string("tests::adds_numbers"), .string("--exact"), .string("--nocapture")]))

        // Verify Cargo test JSON artifact parser selects `profile.test == true` executables.
        let cargoOutput = """
        {"reason":"compiler-artifact","target":{"name":"demo","kind":["lib"],"src_path":"/tmp/polyglot/src/lib.rs"},"profile":{"test":false},"executable":null}
        {"reason":"compiler-artifact","target":{"name":"demo","kind":["lib"],"src_path":"/tmp/polyglot/src/lib.rs"},"profile":{"test":true},"executable":"/tmp/polyglot/target/debug/deps/demo-999"}
        """
        let parsed = RustDebugBuildService.parseBuiltTestExecutablePath(
            from: cargoOutput,
            sourcePath: "/tmp/polyglot/src/lib.rs",
            expectedTargetName: nil
        )
        #expect(parsed == "/tmp/polyglot/target/debug/deps/demo-999")
    }

    @Test
    @MainActor
    func inlineRenameControllerHandlesCommitAndCancelCleanly() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.close() }
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = hostView

        let controller = InlineRenamePanelController()
        var committed: String?
        var cancelledCount = 0

        controller.show(
            initialName: "oldName",
            anchoredTo: NSRect(x: 20, y: 40, width: 60, height: 18),
            in: hostView,
            onCommit: { committed = $0 },
            onCancel: { cancelledCount += 1 }
        )
        #expect(controller.isVisible)

        // Cancelling invokes cancel handler and leaves committed nil.
        controller.cancel()
        #expect(!controller.isVisible)
        #expect(committed == nil)
        #expect(cancelledCount == 1)

        // Committing unchanged name acts as a no-op cancel.
        controller.show(
            initialName: "sameName",
            anchoredTo: NSRect(x: 20, y: 40, width: 60, height: 18),
            in: hostView,
            onCommit: { committed = $0 },
            onCancel: { cancelledCount += 1 }
        )
        controller.commitCurrentValue()
        #expect(!controller.isVisible)
        #expect(committed == nil)
        #expect(cancelledCount == 2)
    }
}

@MainActor
private final class StubGoExecutionSession: LanguageExecutionSession {
    var isRunning = false
    var onOutput: (@Sendable (String) -> Void)?
    var onTermination: (@Sendable (Int32) -> Void)?
    var onStateChange: (@Sendable (LanguageExecutionLifecycleEvent) -> Void)?
    func start(_: LanguageExecutionProcessRequest) throws { isRunning = true }
    func sendInput(_: String) {}
    func stop() { isRunning = false }
}
