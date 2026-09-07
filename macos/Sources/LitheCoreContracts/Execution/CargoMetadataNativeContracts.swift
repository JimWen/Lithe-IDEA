import Foundation

/// One opening and its selected tools, captured before starting native work.
/// The host constructs a fresh command environment from these inputs.
package struct CargoMetadataPreparationRequest: Sendable {
    package let workspaceURL: URL
    package let manifestURL: URL
    package let workspaceGeneration: Int
    package let cargoCandidates: [URL]
    package let rustupCandidates: [URL]
    package let customCargoURL: URL?
    package let environment: [String: String]
    package let deadline: ContinuousClock.Instant

    package init(
        workspaceURL: URL, manifestURL: URL, workspaceGeneration: Int,
        cargoCandidates: [URL], rustupCandidates: [URL], customCargoURL: URL?,
        environment: [String: String], deadline: ContinuousClock.Instant
    ) {
        self.workspaceURL = workspaceURL
        self.manifestURL = manifestURL
        self.workspaceGeneration = workspaceGeneration
        self.cargoCandidates = cargoCandidates
        self.rustupCandidates = rustupCandidates
        self.customCargoURL = customCargoURL
        self.environment = environment
        self.deadline = deadline
    }
}

/// A command plan, not a process owner. The language module creates its capture.
package struct CargoMetadataCommand: Sendable {
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

package struct CargoMetadataNativeInput: Sendable {
    package let workspaceDirectory: String
    package let roots: [ProjectMetadataRoot]

    package init(workspaceDirectory: String, roots: [ProjectMetadataRoot]) {
        self.workspaceDirectory = workspaceDirectory
        self.roots = roots
    }
}

/// Passive filesystem preparation; this port never executes tools or installs SDKs.
package protocol CargoMetadataNativePreparing: Sendable {
    func prepare(_ request: CargoMetadataPreparationRequest) throws -> any CargoMetadataNativeSession
}

/// Owned by one refresh. Calls are serialized on its worker and covered by the
/// request's monotonic deadline. Native identities remain opaque to workflows.
package protocol CargoMetadataNativeSession: Sendable {
    var resolutionCommands: [CargoMetadataCommand] { get }
    /// Outputs correspond exactly to resolutionCommands in the same order.
    /// The caller has already checked success, EOF, cleanup and capture identity.
    func metadataCommand(resolutionOutputs: [Data]) throws -> CargoMetadataCommand
    /// Verifies only typed metadata paths and freezes their native root mapping;
    /// it must never infer permission from a normalizer's error text.
    func normalizationInput(metadata: Data) throws -> CargoMetadataNativeInput
    /// Rechecks the relevant files and tool identities before publication.
    func validate() throws
}
