import SwiftUI

/// Central hub for ephemeral toast notifications.
///
/// SRP: Only manages the toast queue and auto-dismissal.
@Observable
@MainActor
final class ToastCenter {
    var toasts: [ToastMessage] = []

    private let autoDismissAfter: TimeInterval

    init(autoDismissAfter: TimeInterval = 3.0) {
        self.autoDismissAfter = autoDismissAfter
    }

    func show(_ text: String, kind: ToastKind = .info) {
        let message = ToastMessage(kind: kind, text: text)
        toasts.append(message)
        Task {
            try? await Task.sleep(for: .seconds(autoDismissAfter))
            toasts.removeAll { $0.id == message.id }
        }
    }
}
