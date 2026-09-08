import Foundation

/// A command plan, not a process owner. The language module creates its capture.
package struct ProjectMetadataCommand: Sendable {
    package let executablePath: String
    package let arguments: [String]
    package let workingDirectory: String
    package let environment: [String: String]

    package init(
        executablePath: String, arguments: [String], workingDirectory: String,
        environment: [String: String]
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
}

/// One capture round produced by the preparer. `commands` runs in order; the
/// session decides after each round whether more rounds are needed. `id` is a
/// stable stage name that flows into diagnostics and is echoed back to the
/// session that issued it.
package struct ProjectMetadataCaptureStage: Sendable {
    package let id: String
    package let commands: [ProjectMetadataCommand]

    package init(id: String, commands: [ProjectMetadataCommand]) {
        self.id = id
        self.commands = commands
    }
}

/// The collected outputs of one language's staged capture, in the shape the
/// normalizer consumes. `outputs` alignment with the issued commands is the
/// session's responsibility, never inferred from content.
package enum ProjectMetadataNormalizationSource: Sendable {
    case cargo(Data)
    case go(modules: Data, packages: [Data])
}

package enum ProjectMetadataStageOutcome: Sendable {
    /// Another round is required before normalization.
    case more(ProjectMetadataCaptureStage)
    /// Collection is complete and normalization may start.
    case done(ProjectMetadataNormalizationSource)
}

package struct ProjectMetadataNativeInput: Sendable {
    package let workspaceDirectory: String
    package let roots: [ProjectMetadataRoot]

    package init(workspaceDirectory: String, roots: [ProjectMetadataRoot]) {
        self.workspaceDirectory = workspaceDirectory
        self.roots = roots
    }
}

/// Passive filesystem preparation; this port never executes tools or installs SDKs.
package protocol ProjectMetadataNativePreparing: Sendable {
    func prepare(_ request: CargoMetadataPreparationRequest) throws -> any ProjectMetadataNativeSession
}

/// Owned by one refresh. Calls are serialized on its worker and covered by the
/// request's monotonic deadline. Native identities remain opaque to workflows.
///
/// The staged shape exists because command counts and working directories can
/// depend on earlier rounds' output: Go locates its workspace first and then
/// lists one package set per discovered module. Callers bound the number of
/// rounds and the per-round command count defensively.
package protocol ProjectMetadataNativeSession: Sendable {
    /// First round's commands. Independent of any output, known at prepare time.
    var initialStage: ProjectMetadataCaptureStage { get }

    /// Delivers the previous stage's stdout aligned with `stage.commands` in
    /// the same order and length, and returns the next round or the final
    /// normalization source.
    func advance(
        stage: ProjectMetadataCaptureStage, outputs: [Data]
    ) throws -> ProjectMetadataStageOutcome

    /// Converts the completed capture source into the normalization input.
    func normalizationInput(_ source: ProjectMetadataNormalizationSource) throws
        -> ProjectMetadataNativeInput

    /// Rechecks every file and tool identity frozen so far before publication.
    func validate() throws
}
