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
                }
                Text(LocalizedStringKey(notification.message))
                    .font(.system(size: 13))
                    .foregroundStyle(LitheTheme.primaryText)
                    .textSelection(.enabled)
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

    var body: some View {
        if !model.activeNotifications.isEmpty {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(model.activeNotifications) { notification in
                    HStack(alignment: .top, spacing: 4) {
                        WorkbenchNotificationContent(notification: notification)
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
            .onHover { model.setNotificationStackHovered($0) }
            .padding(.trailing, model.workspaceURL == nil ? 12 : WorkbenchLayoutMetrics.rightActivityBarWidth + 12)
            .padding(.bottom, model.workspaceURL == nil ? 12 : LitheTheme.Metrics.statusBarHeight + 12)
        }
    }
}
