import Foundation
import LitheCoreContracts

@MainActor
extension AppModel {
    func goToolchainDidChange() {
        projectToolTasksIfActive?.invalidateWorkspace()
        goProjectFeatureIfActive?.invalidateWorkspace()
    }
    func startGoTool(_ action: ProjectToolAction, location: ProjectMetadataLocation) {
        guard location.rootID == "workspace", let identity = currentWorkspaceIdentity else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await activateExecutionModule()
            guard currentWorkspaceIdentity == identity, let tasks = projectToolTasksIfActive else { return }
            if let id = tasks.start(ProjectToolActionRequest(action: action, directory: location.relativePath),
                workspaceURL: identity.url, workspaceGeneration: identity.generation) {
                runFeatureIfActive?.selectedToolTaskID = id
                isRunVisible = true
            } else if let error = tasks.errorMessage { showNotification(error) }
        }
    }
    func canRerunGoTool(_ task: ProjectToolTaskSnapshot) -> Bool {
        task.state.isTerminal && currentWorkspaceIdentity?.url.standardizedFileURL == task.owner.workspaceURL
            && currentWorkspaceIdentity?.generation == task.owner.workspaceGeneration
    }
    func rerunGoTool(_ task: ProjectToolTaskSnapshot) {
        guard canRerunGoTool(task), let tasks = projectToolTasksIfActive else { return }
        if let id = tasks.start(task.action, workspaceURL: task.owner.workspaceURL,
                              workspaceGeneration: task.owner.workspaceGeneration) {
            runFeatureIfActive?.selectedToolTaskID = id
        } else if let error = tasks.errorMessage { showNotification(error) }
    }
}
