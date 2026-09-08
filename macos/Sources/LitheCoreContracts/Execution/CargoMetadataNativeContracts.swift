import Foundation

/// One opening and its selected tools, captured before starting native work.
/// The host constructs a fresh command environment from these inputs. The
/// candidate fields keep their historical names; a language module fills them
/// with its own resolved tool candidates.
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
