import Foundation
import UserNotifications

/// Wraps `UNUserNotificationCenter`, safely no-ops when running outside a bundle.
///
/// SRP: Only sends system notifications. No UI state, no queue.
@MainActor
final class SystemNotifier {

    private let isRunningAsBundle: Bool = {
        Bundle.main.bundleIdentifier != nil &&
        Bundle.main.bundlePath.hasSuffix(".app")
    }()

    init() {
        if isRunningAsBundle {
            Task {
                try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    func post(title: String, body: String) {
        guard isRunningAsBundle else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
