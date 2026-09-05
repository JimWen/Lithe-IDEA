import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Project runtime integration")
struct ProjectRuntimeTests {






    @Test
    @MainActor
    func projectRelativeJavaOverridesResolveAgainstProjectRoot() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-project-relative-runtime", isDirectory: true)
            .standardizedFileURL
        let javaHome = root.appendingPathComponent("toolchains/jdk", isDirectory: true).standardizedFileURL
        let service = ProjectRuntimeService(
            runtimeLocator: ProjectRelativeRuntimeLocator(validJavaHomes: [javaHome.path]),
            store: EmptyKeyValueStore()
        )
        service.openProject(at: root)

        #expect(service.javaHomeURL(overridePath: "toolchains/jdk") == javaHome)
    }



    @Test
    @MainActor
    func canceledRuntimeDiscoveryClearsDiscoveringState() async throws {
        let locator = BlockingRuntimeLocator()
        defer { locator.release() }
        let service = ProjectRuntimeService(runtimeLocator: locator, store: EmptyKeyValueStore())
        let task = Task { @MainActor in
            await service.refreshAvailableRuntimes()
        }

        #expect(await locator.waitUntilStarted())
        #expect(service.isDiscovering)

        task.cancel()
        locator.release()
        await task.value

        #expect(!service.isDiscovering)
    }

}



private struct ProjectRelativeRuntimeLocator: RuntimeLocator {
    let validJavaHomes: Set<String>

    func environment() -> [String: String] { [:] }
    func discover() -> RuntimeDiscoveryResult {
        RuntimeDiscoveryResult(javaRuntimes: [])
    }
    func validJavaHome(path: String) -> URL? {
        validJavaHomes.contains(path) ? URL(fileURLWithPath: path, isDirectory: true) : nil
    }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func javaLanguageServerExecutable() -> URL? { nil }
}


private final class BlockingRuntimeLocator: RuntimeLocator, @unchecked Sendable {
    private let started = TestGate()
    private let releaseGate = TestGate()

    func release() {
        releaseGate.open()
    }

    func waitUntilStarted() async -> Bool {
        await started.waitUntilOpen()
    }

    func environment() -> [String: String] { [:] }

    func discover() -> RuntimeDiscoveryResult {
        started.open()
        _ = releaseGate.waitSynchronously()
        return RuntimeDiscoveryResult(javaRuntimes: [])
    }

    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool { false }
    func javaLanguageServerExecutable() -> URL? { nil }
}

private struct EmptyKeyValueStore: KeyValueStore {
    func data(forKey key: String) -> Data? { nil }
    func object(forKey key: String) -> Any? { nil }
    func string(forKey key: String) -> String? { nil }
    func stringArray(forKey key: String) -> [String]? { nil }
    func set(_ value: Any?, forKey key: String) {}
    func removeObject(forKey key: String) {}
}
