import Foundation
import LitheCoreContracts

@MainActor
public final class PythonExecutionCapability: NSObject,
    LanguageRunExtensionProviding,
    LanguageTestExtensionProviding,
    LanguageDebugExtensionProviding {
    public let languageID = pythonLanguageID
    public let debugAdapterLaunch = LanguageDebugAdapterLaunch(
        adapterID: "python",
        transport: .stdio,
        executableNames: ["python3", "python"],
        arguments: ["-m", "debugpy.adapter"]
    )
    private let sessionFactory: @MainActor () -> any LanguageExecutionSession

    public init(executionSession: any LanguageExecutionSession) {
        sessionFactory = { executionSession }
    }

    init(sessionFactory: @escaping @MainActor () -> any LanguageExecutionSession) {
        self.sessionFactory = sessionFactory
    }

    public func makeExecutionSession() -> any LanguageExecutionSession {
        sessionFactory()
    }

    public func makeTestExecutionSession() -> any LanguageExecutionSession {
        sessionFactory()
    }

    public func launchPlan(
        for request: LanguageRunExtensionRequest
    ) throws -> LanguageRunExtensionPlan {
        let path = try Self.checkedRelativePath(request.relativeFilePath)
        return LanguageRunExtensionPlan(
            executable: .toolchain("project-python"),
            arguments: [path] + request.arguments,
            environment: request.environment
        )
    }

    public func discoverTests(
        for request: LanguageTestExtensionDiscoveryRequest
    ) throws -> [LanguageTestExtensionItem] {
        let paths = try request.relativeProjectFilePaths.map(Self.checkedRelativePath)
        guard Self.isPythonTestProject(paths) else { return [] }
        let files = paths
            .filter(Self.isTestFile)
            .sorted()
            .map { path in
                LanguageTestExtensionItem(
                    id: "python:file:\(path)",
                    label: path,
                    kind: .file,
                    relativeFilePath: path
                )
            }
        return [LanguageTestExtensionItem(
            id: "python:workspace",
            label: "All Python Tests",
            kind: .workspace
        )] + files
    }

    public func testPlan(
        for request: LanguageTestExtensionRequest
    ) throws -> LanguageTestExtensionPlan {
        let projectPaths = try request.relativeProjectFilePaths.map(Self.checkedRelativePath)
        guard Self.isPythonTestProject(projectPaths) else {
            throw LanguageTestExtensionError.unsupportedProject(languageID: languageID)
        }
        let arguments: [String]
        let label: String
        switch request.scope {
        case .workspace:
            arguments = ["-m", "pytest"]
            label = "All Python Tests"
        case .file(let relativePath):
            let path = try Self.checkedRelativePath(relativePath)
            arguments = ["-m", "pytest", path]
            label = path.split(separator: "/").last.map(String.init) ?? path
        case .testCase(let identifier, let relativeFilePath):
            let name = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("\n"), !name.contains("\r") else {
                throw LanguageTestExtensionError.invalidTestIdentifier
            }
            if let relativeFilePath {
                let path = try Self.checkedRelativePath(relativeFilePath)
                arguments = ["-m", "pytest", "\(path)::\(name)"]
            } else {
                arguments = ["-m", "pytest", "-k", name]
            }
            label = name
        }
        return LanguageTestExtensionPlan(
            label: label,
            frameworkID: "pytest",
            launchPlan: LanguageRunExtensionPlan(
                executable: .toolchain("project-python"),
                arguments: arguments
            )
        )
    }

    private static func checkedRelativePath(_ value: String) throws -> String {
        let path = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else {
            throw LanguageTestExtensionError.invalidRelativePath
        }
        return path
    }

    private static func isPythonTestProject(_ paths: [String]) -> Bool {
        let names = Set(paths.map { $0.split(separator: "/").last.map(String.init)?.lowercased() ?? "" })
        if !names.isDisjoint(with: ["pyproject.toml", "pytest.ini", "setup.cfg", "setup.py", "tox.ini", "requirements.txt"]) {
            return true
        }
        return paths.contains(where: isTestFile)
    }

    private static func isTestFile(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        return (name.hasPrefix("test_") && name.hasSuffix(".py")) || name.hasSuffix("_test.py")
    }
}
