import Foundation

private enum WorkbenchNotificationTiming {
    static let maximumVisibleCount = 3

    static func displayDuration(for notification: WorkbenchNotification) -> Duration {
        switch notification.severity {
        case .error: .seconds(12)
        case .warning: .seconds(8)
        case .information, .success: .seconds(4)
        }
    }
}

extension AppModel {
    func showNotification(
        _ message: String,
        severity: WorkbenchNotificationSeverity = .information,
        title: String? = nil
    ) {
        let notification = WorkbenchNotification(message: message, title: title, severity: severity)
        notifications.insert(notification, at: 0)
        if notifications.count > 100 {
            notifications.removeLast(notifications.count - 100)
        }

        activeNotifications.append(notification)
        if activeNotifications.count > WorkbenchNotificationTiming.maximumVisibleCount {
            let removed = activeNotifications.removeFirst()
            cancelNotificationDismissal(for: removed.id)
        }
        if areNotificationsHovered {
            notificationRemainingDurations[notification.id] = WorkbenchNotificationTiming.displayDuration(for: notification)
        } else {
            scheduleNotificationDismissal(
                for: notification,
                after: WorkbenchNotificationTiming.displayDuration(for: notification)
            )
        }
    }

    func setNotificationStackHovered(_ isHovered: Bool) {
        guard areNotificationsHovered != isHovered else { return }
        areNotificationsHovered = isHovered

        if isHovered {
            let now = ContinuousClock().now
            for notification in activeNotifications {
                if let deadline = notificationDismissalDeadlines.removeValue(forKey: notification.id) {
                    notificationRemainingDurations[notification.id] = now < deadline
                        ? now.duration(to: deadline)
                        : .zero
                }
                notificationDismissalTasks.removeValue(forKey: notification.id)?.cancel()
            }
        } else {
            for notification in activeNotifications {
                let remaining = notificationRemainingDurations.removeValue(forKey: notification.id)
                    ?? WorkbenchNotificationTiming.displayDuration(for: notification)
                scheduleNotificationDismissal(for: notification, after: remaining)
            }
        }
    }

    func dismissNotification(_ id: UUID) {
        guard activeNotifications.contains(where: { $0.id == id }) else { return }
        activeNotifications.removeAll { $0.id == id }
        cancelNotificationDismissal(for: id)
    }

    func markAllNotificationsRead() {
        for index in notifications.indices {
            notifications[index].isRead = true
        }
    }

    func clearNotifications() {
        notifications.removeAll()
        activeNotifications.removeAll()
        for task in notificationDismissalTasks.values {
            task.cancel()
        }
        notificationDismissalTasks.removeAll()
        notificationDismissalDeadlines.removeAll()
        notificationRemainingDurations.removeAll()
        areNotificationsHovered = false
    }

    private func scheduleNotificationDismissal(
        for notification: WorkbenchNotification,
        after duration: Duration
    ) {
        notificationDismissalTasks[notification.id]?.cancel()
        let deadline = ContinuousClock().now.advanced(by: duration)
        notificationDismissalDeadlines[notification.id] = deadline
        notificationDismissalTasks[notification.id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self,
                  !self.areNotificationsHovered,
                  self.notificationDismissalDeadlines[notification.id] == deadline else { return }
            self.dismissNotification(notification.id)
        }
    }

    private func cancelNotificationDismissal(for id: UUID) {
        notificationDismissalTasks.removeValue(forKey: id)?.cancel()
        notificationDismissalDeadlines.removeValue(forKey: id)
        notificationRemainingDurations.removeValue(forKey: id)
    }
}
