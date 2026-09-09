import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Project runtime integration")
struct ProjectRuntimeTests {






    @Test
    @MainActor
    func languageExecutablesPersistPerProjectAndDriveLaunchEnvironment() throws {
        let store = RuntimeOverrideStore()
        let locator = SelectedToolRuntimeLocator()
        let service = ProjectRuntimeService(runtimeLocator: locator, store: store)
        let first = URL(fileURLWithPath: "/workspace/alpha")
        let second = URL(fileURLWithPath: "/workspace/beta")
        service.openProject(at: first)
        defer { service.closeProject() }
        try service.setCustomExecutablePath("/toolchains/custom/bin/go", for: "go")
        #expect(service.executableOnPath("go")?.path == "/toolchains/custom/bin/go")
        #expect(service.processEnvironment()["PATH"] == "/toolchains/custom/bin:/system/bin")
        service.openProject(at: second)
        #expect(service.customExecutablePath(for: "go") == nil)
        #expect(service.executableOnPath("go")?.path == "/system/bin/go")
        service.openProject(at: first)
        #expect(service.executableOnPath("go")?.path == "/toolchains/custom/bin/go")
        #expect(throws: RunExecutableResolutionError.self) {
            try service.setCustomExecutablePath("/missing/go", for: "go")
        }
        #expect(service.executableOnPath("go")?.path == "/toolchains/custom/bin/go")
        try service.setCustomExecutablePath("", for: "go")
        #expect(service.executableOnPath("go")?.path == "/system/bin/go")
        #expect(service.processEnvironment(overrides: ["PATH": "/run/override"])["PATH"] == "/run/override")
    }

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
    func projectRuntimeOverrideIsPersistedInLitheDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-runtime-(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("toolchains/go/bin/go")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = ProjectRuntimeService(runtimeLocator: SelectedToolRuntimeLocator(), store: EmptyKeyValueStore(), fileStorage: MacFileStorage())
        service.openProject(at: root)
        try service.setCustomExecutablePath(executable.path, for: "go")

        let settings = root.appendingPathComponent(".lithe/runtime.json")
        #expect(FileManager.default.fileExists(atPath: settings.path))
        let reloaded = ProjectRuntimeService(runtimeLocator: SelectedToolRuntimeLocator(), store: EmptyKeyValueStore(), fileStorage: MacFileStorage())
        reloaded.openProject(at: root)
        #expect(reloaded.customExecutablePath(for: "go") == executable.path)
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

private struct SelectedToolRuntimeLocator: RuntimeLocator {
    func environment() -> [String: String] { ["PATH": "/system/bin"] }
    func discover() -> RuntimeDiscoveryResult { RuntimeDiscoveryResult(javaRuntimes: []) }
    func validJavaHome(path: String) -> URL? { nil }
    func javaRuntime(at homeURL: URL) -> JavaRuntimeCandidate? { nil }
    func isExecutable(at url: URL) -> Bool {
        ["/toolchains/custom/bin/go", "/system/bin/go"].contains(url.path)
            || FileManager.default.isExecutableFile(atPath: url.path)
    }
}

private final class RuntimeOverrideStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func set(_ value: Any?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}
