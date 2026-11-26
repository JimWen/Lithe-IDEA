import Foundation
import LitheCoreContracts
import Testing
@testable import Lithe

@Suite("Project Environment, Dependency Parsers & External Libraries", .serialized)
@MainActor
struct ProjectEnvironmentAndLibrariesTests {
    private final class InMemoryStore: KeyValueStore {
        private var values: [String: Any] = [:]
        func object(forKey defaultName: String) -> Any? { values[defaultName] }
        func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
        func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }
        func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
        func set(_ value: Any?, forKey defaultName: String) {
            if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
        }
    }

    private struct StaticLogDir: LogDirectoryProviding {
        var defaultLogDirectory: URL { FileManager.default.temporaryDirectory }
    }

    private final class StubInspector: ProjectEnvironmentInspecting, @unchecked Sendable {
        let goSnapshot: GoProjectEnvironmentSnapshot?
        let rustSnapshot: RustProjectEnvironmentSnapshot?
        let pythonSnapshot: PythonProjectEnvironmentSnapshot?
        let directoryEntries: [String: [ExternalLibraryFileEntry]]
        private let lock = NSLock()
        private(set) var cancelledOperationIDs: [String] = []
        private(set) var inspectedPythonCount = 0

        init(
            goSnapshot: GoProjectEnvironmentSnapshot? = nil,
            rustSnapshot: RustProjectEnvironmentSnapshot? = nil,
            pythonSnapshot: PythonProjectEnvironmentSnapshot? = nil,
            directoryEntries: [String: [ExternalLibraryFileEntry]] = [:]
        ) {
            self.goSnapshot = goSnapshot
            self.rustSnapshot = rustSnapshot
            self.pythonSnapshot = pythonSnapshot
            self.directoryEntries = directoryEntries
        }

        func inspectGo(workspaceURL: URL, manifestURL: URL?, executableURL: URL?, environment: [String: String], operationID: String) -> GoProjectEnvironmentSnapshot {
            goSnapshot ?? UnavailableProjectEnvironmentInspector().inspectGo(
                workspaceURL: workspaceURL, manifestURL: manifestURL, executableURL: executableURL, environment: environment, operationID: operationID
            )
        }

        func inspectRust(workspaceURL: URL, manifestURL: URL?, cargoURL: URL?, environment: [String: String], operationID: String) -> RustProjectEnvironmentSnapshot {
            rustSnapshot ?? UnavailableProjectEnvironmentInspector().inspectRust(
                workspaceURL: workspaceURL, manifestURL: manifestURL, cargoURL: cargoURL, environment: environment, operationID: operationID
            )
        }

        func inspectPython(workspaceURL: URL, manifestURL: URL?, pythonURL: URL?, environment: [String: String], operationID: String) -> PythonProjectEnvironmentSnapshot {
            lock.lock()
            inspectedPythonCount += 1
            lock.unlock()
            return pythonSnapshot ?? UnavailableProjectEnvironmentInspector().inspectPython(
                workspaceURL: workspaceURL, manifestURL: manifestURL, pythonURL: pythonURL, environment: environment, operationID: operationID
            )
        }

        func cancelInspection(operationID: String) {
            lock.lock()
            cancelledOperationIDs.append(operationID)
            lock.unlock()
        }

        func listDirectory(at url: URL) -> [ExternalLibraryFileEntry] {
            directoryEntries[url.standardizedFileURL.path] ?? []
        }
    }

    @Test
    func goModParserResolvesDirectIndirectReplacementsAndModuleCacheEscaping() {
        let goMod = """
        module github.com/acme/service

        go 1.24.0
        toolchain go1.24.1

        require (
            github.com/Azure/go-autorest v14.2.0
            github.com/gin-gonic/gin v1.10.0
            golang.org/x/sys v0.28.0 // indirect
        )

        require github.com/acme/localpkg v0.0.0

        replace github.com/acme/localpkg => ../localpkg
        replace github.com/gin-gonic/gin => github.com/fork/gin v1.10.1
        """

        let parsed = ProjectDependencyParsers.parseGoMod(goMod)
        #expect(parsed.moduleName == "github.com/acme/service")
        #expect(parsed.goDirective == "1.24.0")
        #expect(parsed.toolchain == "go1.24.1")
        #expect(parsed.requirements.count == 4)
        #expect(parsed.replacements.count == 2)
        #expect(ProjectDependencyParsers.escapeGoModulePath("github.com/Azure/go-autorest") == "github.com/!azure/go-autorest")

        let existingDirs: Set<String> = [
            "/cache/github.com/!azure/go-autorest@v14.2.0",
            "/cache/github.com/fork/gin@v1.10.1",
            "/repo/localpkg",
        ]
        let deps = ProjectDependencyParsers.resolveGoDependencies(
            parsed: parsed,
            manifestURL: URL(fileURLWithPath: "/repo/service/go.mod"),
            goModCache: "/cache",
            directoryExists: { existingDirs.contains($0.standardizedFileURL.path) }
        )
        #expect(deps.count == 4)
        // Direct dependencies sort before indirect dependencies.
        #expect(deps.last?.name == "golang.org/x/sys")
        #expect(deps.last?.isDirect == false)
        #expect(deps.last?.sourceDirectoryURL == nil)

        let azure = deps.first { $0.name == "github.com/Azure/go-autorest" }
        #expect(azure?.sourceDirectoryURL?.path == "/cache/github.com/!azure/go-autorest@v14.2.0")

        let gin = deps.first { $0.name == "github.com/gin-gonic/gin" }
        #expect(gin?.replaceTarget == "github.com/fork/gin v1.10.1")
        #expect(gin?.sourceDirectoryURL?.path == "/cache/github.com/fork/gin@v1.10.1")

        let local = deps.first { $0.name == "github.com/acme/localpkg" }
        #expect(local?.replaceTarget == "../localpkg")
        #expect(local?.sourceDirectoryURL?.path == "/repo/localpkg")
    }

    @Test
    func cargoAndPythonDependencyParsersExtractCratesLockVersionsAndPackages() {
        let cargoToml = """
        [package]
        name = "demo-app"
        version = "0.1.0"

        [dependencies]
        serde = { version = "1.0", features = ["derive"] }
        local_util = { path = "../local_util" }
        my_log = { package = "tracing", version = "0.1" }

        [dev-dependencies]
        tempfile = "3.14"
        """
        let cargoLock = """
        [[package]]
        name = "demo-app"
        version = "0.1.0"
        dependencies = [
            "rand 0.9.0",
            "serde",
        ]

        [[package]]
        name = "rand"
        version = "0.8.5"

        [[package]]
        name = "rand"
        version = "0.9.0"

        [[package]]
        name = "serde"
        version = "1.0.219"

        [[package]]
        name = "tracing"
        version = "0.1.41"
        """
        let parsedCargo = ProjectDependencyParsers.parseCargoToml(cargoToml)
        #expect(parsedCargo.crateName == "demo-app")
        #expect(parsedCargo.dependencies.count == 4)
        let myLog = parsedCargo.dependencies.first { $0.name == "my_log" }
        #expect(myLog?.packageName == "tracing")
        let lockPackages = ProjectDependencyParsers.parseCargoLockPackages(cargoLock)
        #expect(ProjectDependencyParsers.resolveCargoLockedVersion(
            packageName: "rand",
            versionRequirement: "0.9",
            ownerCrateName: "demo-app",
            lockPackages: lockPackages
        ) == "0.9.0")
        #expect(ProjectDependencyParsers.resolveCargoLockedVersion(
            packageName: "rand",
            versionRequirement: "0.9",
            ownerCrateName: nil,
            lockPackages: lockPackages
        ) == "0.9.0")
        #expect(ProjectDependencyParsers.resolveCargoLockedVersion(
            packageName: "serde",
            versionRequirement: "1.0",
            ownerCrateName: "demo-app",
            lockPackages: lockPackages
        ) == "1.0.219")

        // Regression: extras `[standard]` inside quoted entry must NOT prematurely terminate the array.
        let pyproject = """
        [project]
        name = "demo"
        dependencies = [
            "uvicorn[standard]==0.32.0",
            "fastapi>=0.115.0",
            "httpx[http2]>=0.27.0",
        ]
        """
        let pyDeps = ProjectDependencyParsers.parsePyprojectDependencies(
            pyproject,
            manifestURL: URL(fileURLWithPath: "/repo/pyproject.toml")
        )
        #expect(pyDeps.map(\.name) == ["fastapi", "httpx", "uvicorn"])
        #expect(pyDeps.first?.version == ">=0.115.0")

        let pipfile = """
        [packages]
        requests = ">=2.31"
        flask = {version = "==3.0.3"}

        [dev-packages]
        pytest = "*"
        """
        let pipfileDeps = ProjectDependencyParsers.parsePipfileDependencies(
            pipfile,
            manifestURL: URL(fileURLWithPath: "/repo/Pipfile")
        )
        #expect(pipfileDeps.map(\.name) == ["flask", "requests", "pytest"])
        #expect(pipfileDeps.first(where: { $0.name == "pytest" })?.isDirect == false)

        let reqs = """
        # Comment line
        -r base.txt
        pytest>=8.0.0
        httpx==0.27.2 ; python_version >= "3.10"
        """
        let reqDeps = ProjectDependencyParsers.parsePythonRequirements(
            reqs,
            manifestURL: URL(fileURLWithPath: "/repo/requirements.txt")
        )
        #expect(reqDeps.map(\.name) == ["httpx", "pytest"])
        #expect(reqDeps.first?.version == "==0.27.2")
    }

    @Test
    func goModSyntaxProfileMatchesGoModAndGoWorkFilenames() {
        let registry = LanguageSyntaxProfileRegistry.shared
        let goMod = registry.profile(forFileName: "go.mod", fileExtension: "mod")
        #expect(goMod.languageID == "gomod")
        #expect(goMod.keywords.contains("require"))
        #expect(goMod.keywords.contains("replace"))

        let goWork = registry.profile(forFileName: "go.work", fileExtension: "work")
        #expect(goWork.languageID == "gomod")
        #expect(goWork.keywords.contains("use"))
    }

    @Test
    func projectRuntimeServicePersistsEnvironmentOverridesAndInjectsProcessEnvironment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-runtime-env-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InMemoryStore()
        let fileStorage = MacFileStorage()
        let service = ProjectRuntimeService(
            runtimeLocator: MacRuntimeLocator(),
            store: store,
            fileStorage: fileStorage
        )
        service.openProject(at: root)

        try service.setCustomEnvironmentValue("/custom/gopath", for: "GOPATH")
        try service.setCustomEnvironmentValue("https://goproxy.cn,direct", for: "GOPROXY")
        #expect(service.customEnvironmentValue(for: "GOPATH") == "/custom/gopath")
        #expect(service.processEnvironment()["GOPATH"] == "/custom/gopath")
        #expect(service.processEnvironment()["GOPROXY"] == "https://goproxy.cn,direct")

        // Reloading from disk `.lithe/runtime.json` preserves environment overrides.
        let reloaded = ProjectRuntimeService(
            runtimeLocator: MacRuntimeLocator(),
            store: InMemoryStore(),
            fileStorage: fileStorage
        )
        reloaded.openProject(at: root)
        #expect(reloaded.customEnvironmentValue(for: "GOPATH") == "/custom/gopath")
        #expect(reloaded.processEnvironment()["GOPROXY"] == "https://goproxy.cn,direct")

        // Clearing an override removes it cleanly.
        try reloaded.setCustomEnvironmentValue("", for: "GOPATH")
        #expect(reloaded.customEnvironmentValue(for: "GOPATH") == nil)

        // Legacy `.lithe/runtime.json` with only `executables` decodes cleanly.
        let legacyURL = root.appendingPathComponent(".lithe/runtime.json")
        try #"{"executables":{"go":"/usr/bin/true"}}"#.write(to: legacyURL, atomically: true, encoding: .utf8)
        reloaded.openProject(at: root)
        #expect(reloaded.customExecutablePath(for: "go") == "/usr/bin/true")
        #expect(reloaded.customEnvironmentOverrides.isEmpty)
    }

    @Test
    func appModelDetectsPythonProjectSettingsAndOpensExternalLibraryFilesReadOnly() async throws {
        let store = InMemoryStore()
        let settings = AppSettings(store: store, logDirectoryProvider: StaticLogDir())
        let stubInspector = StubInspector(
            pythonSnapshot: PythonProjectEnvironmentSnapshot(
                executablePath: "/fake/.venv/bin/python3",
                version: "3.12.7",
                prefixPath: "/fake/.venv",
                basePrefixPath: "/usr/local",
                isVirtualEnvironment: true,
                virtualEnvName: ".venv",
                stdLibURL: nil,
                sitePackagesURLs: [],
                pythonPath: nil,
                manifestURL: nil,
                dependencies: []
            )
        )
        let container = MacServiceContainer(
            store: store,
            settings: settings,
            moduleLaunchMode: .safeMode,
            projectEnvironmentInspector: stubInspector
        )
        container.moduleLifecycleCoordinator.stop()
        let model = AppModel(settings: settings, services: container.services)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-py-env-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        let extLibDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lithe-extlib-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extLibDir, withIntermediateDirectories: true)
        let pyproject = root.appendingPathComponent("pyproject.toml")
        try "[project]\nname = \"demo\"\ndependencies = [\"pytest>=8.0\"]\n".write(to: pyproject, atomically: true, encoding: .utf8)
        let extFile = extLibDir.appendingPathComponent("helper.go")
        try "package helper\nfunc Greet() string { return \"hi\" }\n".write(to: extFile, atomically: true, encoding: .utf8)
        defer {
            RustCoreBridge().invalidateSearchIndex(at: root)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: extLibDir)
        }

        model.openProjectDirectly(root)
        let loaded = await awaitChange(on: model.workspaceFeature) {
            model.projectFiles.contains { $0.lastPathComponent == "pyproject.toml" }
        }
        #expect(loaded)
        let inspected = await awaitChange(on: model) {
            model.projectEnvironmentSnapshot.python?.version == "3.12.7"
        }
        #expect(inspected)
        #expect(model.hasDetectedPythonProject)
        #expect(model.projectEnvironmentSnapshot.python?.version == "3.12.7")
        #expect(model.availableSettingsCategories.contains(.python))
        #expect(!model.availableSettingsCategories.contains(.go))

        // Opening an external library file opens it strictly read-only with library display prefix.
        model.openExternalLibraryFile(extFile, displayPrefix: "github.com/acme/helper@v1.0.0")
        let opened = await awaitChange(on: model.documentFeature) {
            model.activeDocument?.url.standardizedFileURL == extFile.standardizedFileURL
        }
        #expect(opened)
        #expect(model.activeDocument?.isReadOnly == true)
        #expect(model.activeDocument?.displayPath == "github.com/acme/helper@v1.0.0/helper.go")

        await model.shutdownProjectSession()
        await model.services.moduleRuntime.shutdownAll()
    }
}
