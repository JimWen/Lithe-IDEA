import Foundation

package enum ProjectRunConfigurationStatus: Equatable, Sendable {
    case missing
    case ready
    case invalid(String)
}

package enum RunConfigurationRecoveryAction: Equatable, Sendable {
    case none
    case regenerate
    case editConfiguration
    case fixPermissions
    case upgradeApplication
}

package struct RunConfigurationDiagnostic: Equatable, Identifiable, Sendable {
    package let configurationID: String?
    package let code: String
    package let message: String

    package init(configurationID: String?, code: String, message: String) {
        self.configurationID = configurationID
        self.code = code
        self.message = message
    }

    package var id: String { [configurationID, code, message].compactMap { $0 }.joined(separator: ":") }
}

package struct ProjectRunConfigurationInspection: Equatable, Sendable {
    package let status: ProjectRunConfigurationStatus
    package let diagnostics: [RunConfigurationDiagnostic]
    package var recoveryAction: RunConfigurationRecoveryAction = .none
    package var recoveryPath: String? = nil

    package init(
        status: ProjectRunConfigurationStatus,
        diagnostics: [RunConfigurationDiagnostic],
        recoveryAction: RunConfigurationRecoveryAction = .none,
        recoveryPath: String? = nil
    ) {
        self.status = status
        self.diagnostics = diagnostics
        self.recoveryAction = recoveryAction
        self.recoveryPath = recoveryPath
    }
}

package enum ProjectLoadState: Equatable, Sendable {
    case idle
    case loading(workspace: URL)
    case bound(workspace: URL)
    case ready(workspace: URL, snapshotID: UUID)
    case failed(workspace: URL, message: String)

    package func isReady(for workspace: URL, snapshotID: UUID? = nil) -> Bool {
        guard case .ready(let boundWorkspace, let boundSnapshotID) = self,
              boundWorkspace == workspace.standardizedFileURL else { return false }
        return snapshotID.map { $0 == boundSnapshotID } ?? true
    }

    package func hasReadyInventory(for workspace: URL) -> Bool {
        guard case .ready(let boundWorkspace, _) = self else { return false }
        return boundWorkspace == workspace.standardizedFileURL
    }
}

package enum RunConfigurationGenerationState: Equatable, Sendable {
    case idle
    case projectNotReady
    case succeeded(entryCount: Int)
    case noEntries
    case failed(String)
}

package enum RunConfigurationSaveScope: String, CaseIterable, Identifiable, Sendable {
    case local
    case project

    package var id: String { rawValue }
}

package enum RunConfigurationSource: String, Sendable {
    case generated
    case project
    case local
}

package struct EffectiveRunConfiguration: Sendable {
    package let configuration: RunConfiguration
    package let options: RunOptions
    package var source: RunConfigurationSource = .generated

    package init(
        configuration: RunConfiguration,
        options: RunOptions,
        source: RunConfigurationSource = .generated
    ) {
        self.configuration = configuration
        self.options = options
        self.source = source
    }
}

package struct RunConfigurationResolution: Sendable {
    package let configurations: [EffectiveRunConfiguration]
    package let diagnostics: [RunConfigurationDiagnostic]
    package let defaultConfigurationID: String?
    package let projectToolchain: ProjectToolchainSelection

    package init(
        configurations: [EffectiveRunConfiguration],
        diagnostics: [RunConfigurationDiagnostic],
        defaultConfigurationID: String?,
        projectToolchain: ProjectToolchainSelection = ProjectToolchainSelection()
    ) {
        self.configurations = configurations
        self.diagnostics = diagnostics
        self.defaultConfigurationID = defaultConfigurationID
        self.projectToolchain = projectToolchain
    }
}

package struct RunConfigurationOperationFailure: LocalizedError, Sendable {
    package let message: String

    package init(message: String) { self.message = message }

    package var errorDescription: String? { message }
}

package enum RunConfigurationEditorSaveStage: String, Sendable {
    case prepare
    case write
    case reload
}

package struct RunConfigurationEditorSaveFailure: LocalizedError, Sendable {
    package let stage: RunConfigurationEditorSaveStage
    package let message: String

    package init(stage: RunConfigurationEditorSaveStage, message: String) {
        self.stage = stage
        self.message = message
    }

    package var errorDescription: String? {
        switch stage {
        case .prepare:
            "Could not prepare the run configuration: \(message)"
        case .write:
            "Could not write the run configuration: \(message)"
        case .reload:
            "Changes were saved, but Lithe could not reload them: \(message)"
        }
    }
}

package struct RunConfigurationGenerationResult: Sendable {
    package let entryCount: Int
    package init(entryCount: Int) { self.entryCount = entryCount }
}


package struct RunConfigurationDocumentMutation: Sendable {
    package let configurationID: String?
    package let document: Data

    package init(configurationID: String?, document: Data) {
        self.configurationID = configurationID
        self.document = document
    }
}

package protocol RunConfigurationDocumentMutating: Sendable {
    func updateOptionsDocument(
        at projectURL: URL,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        options: RunOptions
    ) throws -> RunConfigurationDocumentMutation
}

package struct ProjectToolchainSelection: Codable, Equatable, Sendable {
    package var javaHomePath = ""

    package init(
        javaHomePath: String = ""
    ) {
        self.javaHomePath = javaHomePath
    }
}

package protocol RunConfigurationOperations: Sendable {
    func inspect(at projectURL: URL) -> ProjectRunConfigurationInspection
    func generate(
        at projectURL: URL,
        files: [URL],
        modulePaths: [String]
    ) throws -> RunConfigurationGenerationResult
    func resolve(
        at projectURL: URL,
        toolchainCandidates: [ProjectToolchainCandidate]
    ) throws -> RunConfigurationResolution
    func launchPlan(
        at projectURL: URL,
        configurationID: String,
        currentFile: String?,
        classPath: String?,
        debugPort: Int?
    ) throws -> SharedLaunchPlan
    func saveEditorChanges(
        _ options: RunOptions,
        toolchain: ProjectToolchainSelection,
        configurationID: String,
        scope: RunConfigurationSaveScope,
        at projectURL: URL
    ) throws
    func migrateLegacySettings(at projectURL: URL, configurationIDs: [String]) throws
}

package extension RunConfigurationOperations {

    func saveEditorChanges(
        _: RunOptions,
        toolchain _: ProjectToolchainSelection,
        configurationID _: String,
        scope _: RunConfigurationSaveScope,
        at _: URL
    ) throws {
        throw RunConfigurationEditorSaveFailure(
            stage: .prepare,
            message: "Run configuration editor saving is unavailable."
        )
    }
}
