import SwiftUI

extension WorkbenchNotificationSeverity {
    var symbol: String {
        switch self {
        case .information: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "exclamationmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .information: LitheTheme.accent
        case .success: LitheTheme.success
        case .warning: LitheTheme.warning
        case .error: LitheTheme.error
        }
    }
}

struct WorkbenchNotificationContent: View {
    let notification: WorkbenchNotification
    var maximumMessageLines: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notification.severity.symbol)
                .font(.system(size: 18))
                .foregroundStyle(notification.severity.color)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                if let title = notification.title {
                    Text(LocalizedStringKey(title))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LitheTheme.primaryText)
                        .lineLimit(2)
                }
                Text(LocalizedStringKey(notification.message))
                    .font(.system(size: 13))
                    .foregroundStyle(LitheTheme.primaryText)
                    .textSelection(.enabled)
                    .lineLimit(maximumMessageLines)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Shared by project and standalone editor windows. Ordinary saves are silent;
/// actionable failures remain readable and are also retained in Notifications.
struct WorkbenchNotificationStack: View {
    @EnvironmentObject private var model: AppModel
    @State private var expandedNotification: WorkbenchNotification?

    var body: some View {
        if !model.activeNotifications.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(model.activeNotifications) { notification in
                    HStack(alignment: .top, spacing: 4) {
                        VStack(alignment: .leading, spacing: 6) {
                            WorkbenchNotificationContent(notification: notification, maximumMessageLines: 4)
                            if let action = notification.action {
                                Button(action.title) {
                                    model.performNotificationAction(action)
                                    model.dismissNotification(notification.id)
                                }
                                .buttonStyle(LitheSecondaryButtonStyle())
                                .controlSize(.small)
                            }
                            if notification.severity == .error || notification.message.count > 100
                                || notification.message.contains("\n") {
                                Button("Details") {
                                    expandedNotification = notification
                                    model.setNotificationStackHovered(true)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(LitheTheme.accent)
                                .padding(.leading, 30)
                            }
                        }
                        .padding(.vertical, 4)
                        Button {
                            model.dismissNotification(notification.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11))
                        }
                        .litheIconButton()
                        .accessibilityLabel("Dismiss notification")
                        .help("Dismiss notification")
                    }
                    .padding(12)
                    .frame(width: 380, alignment: .topLeading)
                    .background(LitheTheme.notificationBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(LitheTheme.panelBorder, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
                    .accessibilityElement(children: .contain)
                }
            }
            .onHover { model.setNotificationStackHovered($0 || expandedNotification != nil) }
            .popover(item: $expandedNotification, arrowEdge: .leading) { notification in
                ScrollView {
                    WorkbenchNotificationContent(notification: notification)
                        .padding(16)
                }
                .frame(width: 420, height: 280)
                .background(LitheTheme.notificationBackground)
            }
            .onChange(of: expandedNotification?.id) { id in
                if id == nil { model.setNotificationStackHovered(false) }
            }
            .padding(.trailing, model.workspaceURL == nil ? 12 : WorkbenchLayoutMetrics.rightActivityBarWidth + 12)
            .padding(.bottom, model.workspaceURL == nil ? 12 : LitheTheme.Metrics.statusBarHeight + 12)
        }
    }
}
