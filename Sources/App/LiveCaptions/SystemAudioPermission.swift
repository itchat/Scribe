import AppKit
import CoreGraphics
import Foundation

/// Helper for the macOS Screen Recording permission required by ScreenCaptureKit.
///
/// SRP: only the permission flow. The capture actor and view model don't deal
/// with prompting or settings deep-links.
enum SystemAudioPermission {

    enum Status: Sendable, Equatable {
        case granted
        case denied
        case notDetermined
    }

    /// Probe the current grant state without prompting.
    static func current() -> Status {
        // CGPreflightScreenCaptureAccess returns true once the user has
        // granted Screen Recording, false otherwise (including not yet asked).
        // There is no separate "not determined" state on macOS — we surface it
        // by attempting a prompt and seeing if the user reacts.
        return CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    /// Trigger the system prompt. macOS shows a permission dialog the first
    /// time only; subsequent calls are no-ops if the user already declined.
    /// Returns the resulting status.
    @discardableResult
    static func request() async -> Status {
        let granted = CGRequestScreenCaptureAccess()
        return granted ? .granted : .denied
    }

    /// Open System Settings → Privacy & Security → Screen Recording.
    /// Used as the escape hatch when the user previously denied access.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            ?? URL(string: "x-apple.systempreferences:com.apple.preference.security")!
        NSWorkspace.shared.open(url)
    }
}
