import Foundation
import LitheCoreContracts

/// Go-specific argv projection. Native toolchain/path resolution remains in
/// the host; no task here writes run-configuration documents or invokes a shell.
public struct GoToolActionCapability: Sendable {
    public init() {}

    public func plan(for request: ProjectToolActionRequest) throws -> ProjectToolTaskPlan {
        let directory = request.directory
        guard directory == "." || (!directory.isEmpty && !directory.hasPrefix("/")
            && !directory.contains(":") && !directory.contains("\\") && !directory.contains("\0")
            && !directory.split(separator: "/", omittingEmptySubsequences: false).contains(where: {
                $0.isEmpty || $0 == "." || $0 == ".."
            })) else { throw LanguageRunExtensionError.invalidRelativePath }
        let title: String
        let executable: ProjectToolExecutable
        let arguments: [String]
        switch request.action {
        case .build:
            title = "Go Build"; executable = .languageToolchain; arguments = ["build", "./..."]
        case .test:
            title = "Go Test"; executable = .languageToolchain; arguments = ["test", "./..."]
        case .vet:
            title = "Go Vet"; executable = .languageToolchain; arguments = ["vet", "./..."]
        case .checkFormatting:
            title = "Check Formatting"; executable = .companion("gofmt"); arguments = ["-l", "."]
        case .moduleTidy:
            title = "Go Mod Tidy"; executable = .languageToolchain; arguments = ["mod", "tidy"]
        case .moduleDownload:
            title = "Go Mod Download"; executable = .languageToolchain; arguments = ["mod", "download"]
        case .moduleVerify:
            title = "Go Mod Verify"; executable = .languageToolchain; arguments = ["mod", "verify"]
        }
        return ProjectToolTaskPlan(title: title, executable: executable, arguments: arguments,
            workingDirectory: directory, diagnosticSource: "go-tool")
    }
}
