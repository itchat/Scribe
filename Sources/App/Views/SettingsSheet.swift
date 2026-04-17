import SwiftUI
import Domain
import Infrastructure

/// Settings dialog for API configuration, translation options, and batch settings.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var vm: SettingsViewModel
    var onSave: (AppConfig) -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self._vm = State(initialValue: SettingsViewModel(config: config))
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                translationSection
                if vm.translationEngine == .openAI {
                    apiSection
                }
                batchSection
                processingSection
            }
            .formStyle(.grouped)
            .frame(minWidth: 500, minHeight: 400)

            Divider()

            HStack {
                Button("Reset to Defaults") {
                    vm = SettingsViewModel(config: AppConfig())
                }
                .buttonStyle(.borderless)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(vm.toConfig())
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    // MARK: - Sections

    private var apiSection: some View {
        Section("API Configuration") {
            TextField("Base URL", text: $vm.baseURL)
            SecureField("API Key", text: $vm.apiKey)
            TextField("Model", text: $vm.model)
        }
    }

    private var translationSection: some View {
        Section("Translation") {
            Picker("Engine", selection: $vm.translationEngine) {
                Text("OpenAI Translate").tag(TranslationEngine.openAI)
                Text("Google Translate").tag(TranslationEngine.google)
            }
            .pickerStyle(.segmented)

            Toggle("Skip Translation", isOn: $vm.skipTranslation)

            if vm.translationEngine == .openAI {
                Toggle("Fall back to Google on failure", isOn: $vm.enableGoogleFallback)

                DisclosureGroup("Custom Prompt") {
                    TextEditor(text: $vm.customPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                }
            }
        }
    }

    private var batchSection: some View {
        Section("Batch Settings") {
            Stepper("Max chars per batch: \(vm.maxCharsPerBatch)", value: $vm.maxCharsPerBatch, in: 100...10000, step: 100)
            Stepper("Max entries per batch: \(vm.maxEntriesPerBatch)", value: $vm.maxEntriesPerBatch, in: 1...500, step: 10)
        }
    }

    private var processingSection: some View {
        Section("Video Processing") {
            Toggle("Skip Subtitle Burning", isOn: $vm.skipSubtitleBurning)
        }
    }
}
