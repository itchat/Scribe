import SwiftUI
@preconcurrency import Translation
import Domain
import Infrastructure

/// Live Captions window. Big rolling caption text at the bottom, history above,
/// engine picker + Start/Stop button in the toolbar.
struct LiveCaptionsView: View {
    @State private var vm = LiveCaptionsViewModel()

    // ── Selection-popup translation state ──
    /// The currently selected substring inside the transcript pane.
    /// Wired through `SelectableTranscriptView` (an `NSTextView` wrapper);
    /// resets to "" when the user clears the selection.
    @State private var selectedText: String = ""
    /// Latest translation result rendered in the popover.
    @State private var translation: String = ""
    /// Banner inside the popover — "via Apple Translation" / "via Google".
    @State private var translationProvider: String = ""
    /// Drives the `.popover(...)` visibility. Set true when the user
    /// selects non-empty text; reset to false when selection clears or
    /// the popover is dismissed.
    @State private var showTranslation: Bool = false
    /// Apple Translation framework configuration. Bumping this to a new
    /// instance re-fires `.translationTask` so each fresh selection
    /// triggers a translation pass even when the language pair is the
    /// same as last time.
    @State private var translationConfig: TranslationSession.Configuration?
    /// Cache the direction so the Google fallback can look up the same
    /// `(source → target)` codes the Apple session was set up with.
    @State private var translationDirection: InstantTranslator.Direction = .enToZh
    /// Debounce token for selection changes — only the latest fires.
    @State private var selectionDebounceID = UUID()

    private let googleFallback = InstantTranslator()

    var body: some View {
        VStack(spacing: 0) {
            historyView
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Slim status line — the live transcript itself now streams
            // into the notepad area above, so this footer just narrates
            // session state ("Loading…", "Listening…", "Stopping…").
            statusFooter
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(.thinMaterial)
        }
        .frame(minWidth: 560, minHeight: 360)
        .navigationTitle("Live Captions")
        .toolbar { toolbar }
        // Closing the window must end the session. Without this the
        // ScreenCaptureKit stream kept capturing system audio with no window
        // on screen — the macOS recording indicator stayed lit — and the
        // loaded ASR model stayed resident for the life of the process.
        .onDisappear { vm.stop() }
        // Apple Translation: re-fires whenever the user makes a fresh
        // selection (we mutate `translationConfig` to a new instance to
        // force a re-run). Body kept tight + inline because
        // `TranslationSession` isn't Sendable and can't be passed to
        // helper methods. The Google fallback is a separate task.
        .translationTask(translationConfig) { session in
            let text = await MainActor.run { selectedText }
            guard !text.isEmpty else { return }
            do {
                let response = try await session.translate(text)
                await MainActor.run {
                    guard text == selectedText else { return }
                    translation = response.targetText
                    translationProvider = "Apple Translation"
                }
            } catch {
                // Apple failed (e.g. language pack not installed) —
                // schedule a separate task for Google so we don't
                // entangle the session's isolation with the Google
                // actor's.
                await fallbackToGoogle(text: text)
            }
        }
    }

    /// Google-only fallback when Apple's Translation framework throws
    /// (no language pack, unsupported pair, etc.). Runs on MainActor
    /// so it can read/write the SwiftUI view-state directly.
    @MainActor
    private func fallbackToGoogle(text: String) async {
        let direction = translationDirection
        do {
            let translated = try await googleFallback.translate(text, direction: direction)
            guard text == selectedText else { return }
            translation = translated
            translationProvider = "Google Translate"
        } catch {
            translation = "Translation failed: \(error.localizedDescription)"
            translationProvider = ""
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var historyView: some View {
        if isFailedState {
            failureState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.history.isEmpty && vm.currentCaption.isEmpty {
            placeholderState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            historyScroll
        }
    }

    /// AppKit-backed selectable transcript pane. Confirmed history rows
    /// + the in-progress live partial are folded into one `NSTextView`
    /// so a selection can naturally span both. The view drives the
    /// translation popup via `handleSelectionChange`.
    private var historyScroll: some View {
        SelectableTranscriptView(
            history: vm.history,
            currentCaption: vm.currentCaption,
            onSelectionChange: handleSelectionChange
        )
        .popover(isPresented: $showTranslation, arrowEdge: .trailing) {
            translationPopover
        }
    }

    // MARK: - Selection → translation

    private func handleSelectionChange(_ text: String) {
        selectedText = text
        if text.isEmpty {
            showTranslation = false
            return
        }
        // Debounce — when the user is dragging the mouse to extend a
        // selection we don't want to fire a translation on every
        // intermediate character.
        let token = UUID()
        selectionDebounceID = token
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard selectionDebounceID == token else { return }
            guard !selectedText.isEmpty, selectedText == text else { return }
            beginTranslation(of: text)
        }
    }

    private func beginTranslation(of text: String) {
        let direction = InstantTranslator.detectDirection(text)
        translation = ""
        translationProvider = ""
        showTranslation = true

        // Re-fire `.translationTask`. Two cases:
        // 1. Direction changed (or first time) — replace the config.
        //    SwiftUI sees a new value and re-runs.
        // 2. Same direction as last time — `.translationTask` won't
        //    re-fire on equal values, so we call
        //    `configuration.invalidate()` (the official escape hatch
        //    documented at WWDC 2024) to bump its internal generation.
        let langs = direction.appleLangs
        if translationDirection == direction, translationConfig != nil {
            translationConfig?.invalidate()
        } else {
            translationDirection = direction
            translationConfig = TranslationSession.Configuration(
                source: Locale.Language(identifier: langs.source),
                target: Locale.Language(identifier: langs.target)
            )
        }

        // Belt-and-suspenders: Apple Translation sometimes silently
        // hangs (e.g. when the language pack hasn't been downloaded
        // yet and the system prompt didn't surface). Kick a fallback
        // timer — if no provider has populated the popover after 4 s
        // we hand off to Google so the spinner doesn't stick.
        scheduleAppleTimeout(for: text)
    }

    /// 4-second watchdog: if `translationProvider` is still empty by
    /// the time it fires, treat Apple as a no-show and try Google.
    private func scheduleAppleTimeout(for text: String) {
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard text == selectedText, translationProvider.isEmpty else { return }
            await fallbackToGoogle(text: text)
        }
    }

    private var translationPopover: some View {
        // Auto-expanding popover. Each `Text` gets
        // `.fixedSize(horizontal: false, vertical: true)` which forces
        // SwiftUI to give the view its natural wrapped-line height
        // instead of squishing it — combined with no `maxHeight` on
        // the popover frame, the bubble grows as tall as needed for
        // the longest translation. Width is capped so CJK text wraps
        // at a comfortable measure.
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if translation.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Translating…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(translation)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !translationProvider.isEmpty {
                Text(translationProvider)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(minWidth: 280, idealWidth: 360, maxWidth: 460, alignment: .leading)
    }

    @ViewBuilder
    private var statusFooter: some View {
        Text(statusText)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var statusText: String {
        switch vm.state {
        case .idle:          return "Press Start to begin captioning"
        case .loadingModel:  return "Loading \(vm.engine.rawValue) (first run downloads \(vm.engine.downloadSizeLabel))…"
        case .capturing:     return "Listening…"
        case .stopping:      return "Stopping…"
        case .failed:        return ""   // failureState renders the message
        }
    }

    @ViewBuilder
    private var placeholderState: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Live Captions")
                .font(.title3.weight(.medium))

            Text("Captions whatever you hear from your Mac, in real time, locally on Apple Silicon. Press Start to begin.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
    }

    private var isFailedState: Bool {
        if case .failed = vm.state { return true }
        return false
    }

    /// Switching mid-session would force a tear-down — the ViewModel
    /// handles that gracefully but it's a confusing UX, so we just gray
    /// the picker out until the user explicitly stops.
    private var isEngineSwitchDisabled: Bool {
        switch vm.state {
        case .idle, .failed: return false
        case .loadingModel, .capturing, .stopping: return true
        }
    }

    @ViewBuilder
    private var failureState: some View {
        if case .failed(let message) = vm.state {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 460)

                HStack(spacing: 10) {
                    Button("Open System Settings") {
                        vm.openScreenRecordingSettings()
                    }
                    Button("Quit Scribe") {
                        vm.quitToReapplyPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.regular)
            }
            .padding(40)
        }
    }

    // MARK: - Toolbar

    /// Picker label, flagging engines this machine will struggle with.
    ///
    /// On a memory-constrained Mac the LLM-backbone engines need far more
    /// than their weight size suggests, and the failure mode is swapping
    /// rather than an error — so say so before the user commits to a ~1 GB
    /// download.
    private static func pickerLabel(for engine: LiveCaptionEngine) -> String {
        isDemanding(engine)
            ? "\(engine.displayName) — needs more memory"
            : engine.displayName
    }

    /// Whether an engine is a poor fit for this machine's memory.
    ///
    /// Advisory, not a block: the user may know the machine is otherwise
    /// idle, or only need a short session.
    private static func isDemanding(_ engine: LiveCaptionEngine) -> Bool {
        guard MemoryBudget.isConstrained else { return false }
        return engine.isHeavyweight || !MemoryBudget.isComfortable(modelBytes: engine.approximateResidentBytes)
    }

    private var engineHelpText: String {
        let base = "Pick the live-captions engine. Each one downloads its model on first use."
        guard MemoryBudget.isConstrained else { return base }
        return base + String(
            format: " This Mac has %.0f GB of memory, so the larger engines may swap.",
            MemoryBudget.physicalMemoryGB
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // Engine picker on the leading edge — switching swaps the
        // recognizer (DIP) and persists to AppConfig, so the next launch
        // reopens the same choice. Disabled while capturing/loading so
        // the user can't tear down a live session by accident.
        ToolbarItem(placement: .navigation) {
            Picker(
                "Engine",
                selection: Binding(
                    get: { vm.engine },
                    set: { vm.setEngine($0) }
                )
            ) {
                ForEach(LiveCaptionEngine.allCases, id: \.self) { engine in
                    Text(Self.pickerLabel(for: engine)).tag(engine)
                }
            }
            .pickerStyle(.menu)
            .disabled(isEngineSwitchDisabled)
            .help(engineHelpText)
        }

        // Secondary actions on the trailing side, before the Start/Stop
        // primary action — copy, clear, and export. Mirrors the icon-only
        // toolbar idiom from `ContentView`.
        ToolbarItem(placement: .secondaryAction) {
            Button {
                vm.copyTranscriptToClipboard()
            } label: {
                Label("Copy Transcript", systemImage: "doc.on.doc")
            }
            .disabled(!vm.hasContent)
            .help("Copy all captions to the clipboard")
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        ToolbarItem(placement: .secondaryAction) {
            Button(role: .destructive) {
                vm.clearTranscript()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(!vm.hasContent)
            .help("Clear captions and history")
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Button("Export SRT…") { vm.exportSRT() }
                    .disabled(vm.history.isEmpty)
                Button("Export Plain Text…") { vm.exportPlainText() }
                    .disabled(vm.history.isEmpty)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save the transcript to a file")
            .disabled(vm.history.isEmpty)
        }

        ToolbarItem(placement: .primaryAction) {
            switch vm.state {
            case .idle, .failed:
                Button {
                    vm.start()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("r", modifiers: .command)
            case .capturing:
                Button {
                    vm.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("r", modifiers: .command)
            case .loadingModel, .stopping:
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

}
