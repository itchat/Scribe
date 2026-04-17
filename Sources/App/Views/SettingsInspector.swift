import SwiftUI
import Domain
import Infrastructure

/// Settings inspector — auto-applies changes like native macOS Inspectors
/// (Xcode Attributes Inspector, Keynote Format panel, Finder Info).
struct SettingsInspector: View {
    @State private var vm: SettingsViewModel
    var onSave: (AppConfig) -> Void

    init(config: AppConfig, onSave: @escaping (AppConfig) -> Void) {
        self._vm = State(initialValue: SettingsViewModel(config: config))
        self.onSave = onSave
    }

    var body: some View {
        Form {
            translationSection
            if vm.translationEngine == .openAI {
                apiSection
            }
            batchSection
            processingSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: .resetSettings)) { _ in
            vm = SettingsViewModel(config: AppConfig())
            autoSave()
        }
    }

    /// Persist changes silently on every edit.
    private func autoSave() {
        onSave(vm.toConfig())
    }

    // MARK: - Sections

    private var translationSection: some View {
        Section {
            Picker("Engine", selection: $vm.translationEngine) {
                Text("OpenAI").tag(TranslationEngine.openAI)
                Text("Google").tag(TranslationEngine.google)
            }
            .pickerStyle(.segmented)
            .onChange(of: vm.translationEngine) { _, _ in autoSave() }

            Toggle("Skip Translation", isOn: $vm.skipTranslation)
                .onChange(of: vm.skipTranslation) { _, _ in autoSave() }

            if vm.translationEngine == .openAI {
                Toggle("Fall back to Google on failure", isOn: $vm.enableGoogleFallback)
                    .onChange(of: vm.enableGoogleFallback) { _, _ in autoSave() }
            }
        } header: {
            Label("Translation", systemImage: "character.bubble")
        }
    }

    private var apiSection: some View {
        Section {
            LabeledContent("Base URL") {
                TextField("", text: $vm.baseURL, prompt: Text("https://api.openai.com"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(autoSave)
            }
            LabeledContent("API Key") {
                SecureField("", text: $vm.apiKey, prompt: Text("sk-..."))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(autoSave)
            }
            LabeledContent("Model") {
                TextField("", text: $vm.model)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(autoSave)
            }

            DisclosureGroup("System Prompt") {
                TextEditor(text: $vm.customPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: vm.customPrompt) { _, _ in autoSave() }
            }
        } header: {
            Label("OpenAI API", systemImage: "key")
        }
    }

    private var batchSection: some View {
        Section {
            Stepper(value: $vm.maxCharsPerBatch, in: 100...10000, step: 100) {
                LabeledContent("Chars per batch", value: "\(vm.maxCharsPerBatch)")
            }
            .onChange(of: vm.maxCharsPerBatch) { _, _ in autoSave() }

            Stepper(value: $vm.maxEntriesPerBatch, in: 1...500, step: 10) {
                LabeledContent("Entries per batch", value: "\(vm.maxEntriesPerBatch)")
            }
            .onChange(of: vm.maxEntriesPerBatch) { _, _ in autoSave() }
        } header: {
            Label("Batching", systemImage: "square.stack")
        }
    }

    private var processingSection: some View {
        Section {
            Toggle("Skip Subtitle Burning", isOn: $vm.skipSubtitleBurning)
                .onChange(of: vm.skipSubtitleBurning) { _, _ in autoSave() }
        } header: {
            Label("Video Output", systemImage: "film")
        } footer: {
            if vm.skipSubtitleBurning {
                Text("Only subtitle files will be produced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
