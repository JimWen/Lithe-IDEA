import SwiftUI
import LitheCoreContracts
import LitheExecutionModule

/// Tool jobs use the ordinary Run list, status controls and output chrome.
struct ProjectToolTaskToolbar: View {
    @EnvironmentObject private var model: AppModel
    let task: ProjectToolTaskSnapshot
    @ObservedObject var tasks: ProjectToolTaskFeatureModel

    var body: some View {
        Text(ProjectToolTaskPresentation.stateLabel(task.state))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(ProjectToolTaskPresentation.stateColor(task.state))
        Button { tasks.stop(task.id) } label: { Image(systemName: "stop.fill") }
            .litheIconButton().foregroundStyle(LitheTheme.warning)
            .help("Stop task").accessibilityLabel("Stop task")
            .disabled(task.state.isTerminal)
        Button { model.rerunGoTool(task) } label: { LitheSystemIcon(systemImage: "arrow.clockwise") }
            .litheIconButton().help("Rerun task").accessibilityLabel("Rerun task")
            .disabled(!model.canRerunGoTool(task))
        Button { tasks.clearOutput(task.id) } label: { Image(systemName: "trash") }
            .litheIconButton().help("Clear task output").accessibilityLabel("Clear task output")
    }
}

struct ProjectToolTaskOutputView: View {
    @EnvironmentObject private var model: AppModel
    let task: ProjectToolTaskSnapshot

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    RunConfigurationIcon(kind: .process(provider: "go.tool"), size: 22)
                        .frame(width: 34, height: 34)
                        .background(LitheTheme.accent.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Text("Go").font(.system(size: 11)).foregroundStyle(LitheTheme.secondaryText)
                    }
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Working directory").foregroundStyle(LitheTheme.secondaryText)
                    Text(task.action.directory).font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled).lineLimit(2)
                }.font(.system(size: 11.5))
                if let message = task.message {
                    Text(message).font(.system(size: 11)).foregroundStyle(LitheTheme.warning)
                        .textSelection(.enabled).lineLimit(3)
                }
                if task.outputTruncated {
                    Text("Task output reached its size limit.").font(.system(size: 11))
                        .foregroundStyle(LitheTheme.warning)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            Rectangle().fill(LitheTheme.divider).frame(height: 1)
            RunOutputSectionHeader()
            OutputTextView(output: task.output, searchRoots: [task.workingDirectory],
                fileExists: { model.fileExists(at: $0) }, emptyMessage: task.state.isTerminal
                    ? String(localized: "The tool produced no output.")
                    : String(localized: "Waiting for tool output…")) { url, line, column in
                model.openSourceLocation(url: url, line: line, column: column)
            }
        }.accessibilityIdentifier("project-tool-task-output")
    }
}

struct RunOutputSectionHeader: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
            Text("Process output")
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(LitheTheme.secondaryText)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(LitheTheme.sidebar.opacity(0.45))
    }
}

enum ProjectToolTaskPresentation {
    static func stateLabel(_ state: ProjectToolTaskState) -> String {
        switch state {
        case .preparing: String(localized: "Preparing…")
        case .running: String(localized: "Running")
        case .stopping: String(localized: "Stopping…")
        case .succeeded: String(localized: "Succeeded")
        case .failed: String(localized: "Failed")
        case .cancelled: String(localized: "Cancelled")
        case .cleanupRequired: String(localized: "Cleanup pending")
        }
    }
    static func stateColor(_ state: ProjectToolTaskState) -> Color {
        switch state {
        case .running, .succeeded: LitheTheme.success
        case .failed: LitheTheme.error
        case .stopping, .cleanupRequired: LitheTheme.warning
        default: LitheTheme.secondaryText
        }
    }
}
