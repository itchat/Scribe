import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ScribeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowConfigurator())
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Videos…") {
                    openVideosViaPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }

            // Add "Reset Settings to Defaults" under the app menu (after "About")
            CommandGroup(after: .appInfo) {
                Divider()
                Button("Reset Settings to Defaults…") {
                    confirmResetSettings()
                }
            }

            // Ensure ⌘Q always quits (explicit fallback in case SwiftUI defaults
            // don't bind it — e.g., when running via `swift run` without proper bundle).
            CommandGroup(replacing: .appTermination) {
                Button("Quit Scribe") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }

            // Remove the Help menu — we don't have docs to show.
            CommandGroup(replacing: .help) { }
        }
    }

    /// Confirm before posting reset notification, since it's destructive.
    private func confirmResetSettings() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings to defaults?"
        alert.informativeText = "Your API key, model, prompt, and other preferences will be cleared."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            NotificationCenter.default.post(name: .resetSettings, object: nil)
        }
    }

    private func openVideosViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.title = "Select Videos"

        if panel.runModal() == .OK {
            NotificationCenter.default.post(name: .openVideoFiles, object: nil, userInfo: ["urls": panel.urls])
        }
    }
}

extension Notification.Name {
    static let openVideoFiles = Notification.Name("com.scribe.openVideoFiles")
    static let resetSettings = Notification.Name("com.scribe.resetSettings")
}

// MARK: - App Delegate (app-level lifecycle)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Activate the app and bring its window to the front.
        NSApp.setActivationPolicy(.regular)
    }
}

// MARK: - Window Configurator

/// Applies fullscreen + tabbing behavior to the hosting NSWindow.
/// Required because SwiftUI WindowGroup defaults to zoom instead of true fullscreen.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            // Enable native fullscreen: green button → hides menu bar, occupies display.
            window.collectionBehavior.insert(.fullScreenPrimary)
            // Clean title bar: hide title, let toolbar expand to full width.
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            // Disable tabbing (we're a single-window utility).
            window.tabbingMode = .disallowed
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

ScribeApp.main()
