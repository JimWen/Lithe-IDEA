import SwiftUI
import LitheGitModule

/// Keeps repository-scoped commands explicit while the change tree aggregates
/// all repositories in the opened workspace.
struct GitRepositoryPicker: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if model.availableGitRepositoryRoots.count > 1 {
            Picker("Repository", selection: Binding(
                get: { model.gitRepositoryRoot },
                set: { root in
                    guard let root else { return }
                    Task { await model.selectGitRepository(root) }
                }
            )) {
                ForEach(model.availableGitRepositoryRoots, id: \.self) { root in
                    Text(repositoryLabel(root)).tag(Optional(root))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: 220)
            .help("Select the repository for Git commands")
            .disabled(model.isRefreshingGit || model.isCommitting
                || model.isPerformingBranchOperation
                || model.isPerformingStashOperation
                || model.isPerformingShelfOperation
                || model.isPerformingWorktreeOperation
                || model.isResolvingGitOperation)
        }
    }

    private func repositoryLabel(_ root: URL) -> String {
        guard let workspace = model.workspaceURL else { return root.lastPathComponent }
        let prefix = workspace.standardizedFileURL.path + "/"
        let path = root.standardizedFileURL.path
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : root.lastPathComponent
    }
}
