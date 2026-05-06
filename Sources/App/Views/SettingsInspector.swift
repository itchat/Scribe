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
            speechRecognitionSection
            subtitleStyleSection
            processingSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onReceive(NotificationCenter.default.publisher(for: .resetSettings)) { _ in
            vm = SettingsViewModel(config: AppConfig())
            autoSave()
        }
    }

    /// Persist changes silently on every edit. Every editable control wires
    /// `.onChange` (not `.onSubmit`) so changes persist as soon as the user
    /// moves focus away — not only on Enter.
    private func autoSave() {
        onSave(vm.toConfig())
    }

    // MARK: - Translation

    /// Single 3-way Translation section: Off / OpenAI / Google. OpenAI's
    /// fields (base URL, API key, model, system prompt, batching) live
    /// inside this same section, gated by the picker — no second header.
    private var translationSection: some View {
        Section {
            Picker("Mode", selection: $vm.translationMode) {
                ForEach(TranslationMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: vm.translationMode) { _, _ in autoSave() }

            if vm.translationMode == .openAI {
                Toggle("Fall back to Google on failure", isOn: $vm.enableGoogleFallback)
                    .onChange(of: vm.enableGoogleFallback) { _, _ in autoSave() }

                Divider()

                LabeledContent("Base URL") {
                    TextField("", text: $vm.baseURL, prompt: Text("https://api.openai.com"))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: vm.baseURL) { _, _ in autoSave() }
                }
                LabeledContent("API Key") {
                    SecureField("", text: $vm.apiKey, prompt: Text("sk-..."))
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: vm.apiKey) { _, _ in autoSave() }
                }
                LabeledContent("Model") {
                    TextField("", text: $vm.model)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: vm.model) { _, _ in autoSave() }
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

                Divider()

                Stepper(value: $vm.maxCharsPerBatch, in: 100...10000, step: 100) {
                    LabeledContent("Chars per batch", value: "\(vm.maxCharsPerBatch)")
                }
                .onChange(of: vm.maxCharsPerBatch) { _, _ in autoSave() }

                Stepper(value: $vm.maxEntriesPerBatch, in: 1...500, step: 10) {
                    LabeledContent("Entries per batch", value: "\(vm.maxEntriesPerBatch)")
                }
                .onChange(of: vm.maxEntriesPerBatch) { _, _ in autoSave() }
            }
        } header: {
            Label("Translation", systemImage: "character.bubble")
        } footer: {
            footerForTranslationMode
        }
    }

    @ViewBuilder
    private var footerForTranslationMode: some View {
        switch vm.translationMode {
        case .off:    inlineFooter("Original-language SRT only.")
        case .openAI: EmptyView()
        case .google: inlineFooter("No API key required.")
        }
    }

    /// Caption-style helper text that hugs the leading edge of the form
    /// row instead of taking the default centred / right-aligned layout.
    /// One line, terse — no hanging indents.
    private func inlineFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Speech Recognition

    /// Engine picker for the offline burn pipeline. Default is Parakeet v2
    /// (English, ANE-accelerated); switching to a Qwen3 variant downloads
    /// its model on first run and supports Chinese / mixed-language audio.
    private var speechRecognitionSection: some View {
        Section {
            Picker("Engine", selection: $vm.offlineASREngine) {
                ForEach(OfflineASREngine.allCases, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: vm.offlineASREngine) { _, _ in autoSave() }
        } header: {
            Label("Speech Recognition", systemImage: "waveform")
        } footer: {
            inlineFooter("First-run download: \(vm.offlineASREngine.downloadSizeLabel).")
        }
    }

    // MARK: - Subtitle Style

    /// Subtitle styling: font, point size, background mode, distance
    /// from the bottom edge. Every control writes directly into the
    /// underlying `SubtitleStyle` struct — no preset picker, no auto
    /// scaling against the input video; the user dials in concrete
    /// numbers and the burn step honours them.
    private var subtitleStyleSection: some View {
        Section {
            Picker("Font", selection: fontNameBinding) {
                ForEach(Self.curatedFonts, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)

            Stepper(value: fontSizeBinding, in: 8...120, step: 2) {
                LabeledContent("Size", value: "\(vm.subtitleStyle.fontSize)pt")
            }

            Picker("Background", selection: backgroundBinding) {
                Text("Black Box").tag(SubtitleBackgroundChoice.blackBox)
                Text("White Box").tag(SubtitleBackgroundChoice.whiteBox)
                Text("Outline Only").tag(SubtitleBackgroundChoice.outline)
            }
            .pickerStyle(.menu)

            Stepper(value: bottomMarginBinding, in: 0...200, step: 4) {
                LabeledContent("Bottom Margin", value: "\(vm.subtitleStyle.marginVertical)px")
            }
        } header: {
            Label("Subtitle Style", systemImage: "textformat")
        }
    }

    /// Background mode bridges 3 presentation choices onto two ASS
    /// fields (`BorderStyle` + the colour pair). The viewmodel stores
    /// them separately, but as a UX matter "Black Box / White Box /
    /// Outline Only" is what the user is actually choosing between.
    private enum SubtitleBackgroundChoice: Hashable {
        case blackBox, whiteBox, outline
    }

    /// macOS-bundled fonts known to live in /System/Library/Fonts so
    /// libass (via the fontsdir we pass to ffmpeg) actually resolves
    /// them. First entry is the default.
    private static let curatedFonts: [String] = [
        "New York",            // Apple serif (default)
        "Helvetica Neue",      // Apple sans
        "Times",               // classic serif
        "Hiragino Sans GB",    // CJK sans
    ]

    private var fontNameBinding: Binding<String> {
        Binding(
            get: { vm.subtitleStyle.fontName },
            set: { name in
                vm.subtitleStyle.fontName = name
                autoSave()
            }
        )
    }

    private var fontSizeBinding: Binding<Int> {
        Binding(
            get: { vm.subtitleStyle.fontSize },
            set: { size in
                vm.subtitleStyle.fontSize = size
                autoSave()
            }
        )
    }

    private var bottomMarginBinding: Binding<Int> {
        Binding(
            get: { vm.subtitleStyle.marginVertical },
            set: { v in
                vm.subtitleStyle.marginVertical = v
                autoSave()
            }
        )
    }

    private var backgroundBinding: Binding<SubtitleBackgroundChoice> {
        Binding(
            get: {
                let s = vm.subtitleStyle
                if s.borderStyle == .outline { return .outline }
                return s.outlineColorARGB == 0xFFFFFFFF ? .whiteBox : .blackBox
            },
            set: { choice in
                switch choice {
                case .blackBox:
                    vm.subtitleStyle.borderStyle = .opaqueBox
                    vm.subtitleStyle.outlineColorARGB = 0xFF000000
                    vm.subtitleStyle.primaryColorARGB = 0xFFFFFFFF
                case .whiteBox:
                    vm.subtitleStyle.borderStyle = .opaqueBox
                    vm.subtitleStyle.outlineColorARGB = 0xFFFFFFFF
                    vm.subtitleStyle.primaryColorARGB = 0xFF000000
                case .outline:
                    vm.subtitleStyle.borderStyle = .outline
                    vm.subtitleStyle.outlineColorARGB = 0xFF000000
                    vm.subtitleStyle.primaryColorARGB = 0xFFFFFFFF
                }
                autoSave()
            }
        )
    }

    // MARK: - Video Output

    private var processingSection: some View {
        Section {
            Toggle("Skip Subtitle Burning", isOn: $vm.skipSubtitleBurning)
                .onChange(of: vm.skipSubtitleBurning) { _, _ in autoSave() }
        } header: {
            Label("Video Output", systemImage: "film")
        } footer: {
            if vm.skipSubtitleBurning {
                inlineFooter("SRT files only.")
            }
        }
    }
}
