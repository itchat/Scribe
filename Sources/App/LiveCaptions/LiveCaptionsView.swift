import SwiftUI
import Domain

/// Live Captions window. Big rolling caption text at the bottom, history above,
/// engine picker + Start/Stop button in the toolbar.
struct LiveCaptionsView: View {
    @State private var vm = LiveCaptionsViewModel()

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

    /// ID used to scroll the live (in-progress) partial into view as it
    /// grows. A constant string avoids re-creating identity on each update,
    /// which would otherwise re-trigger LazyVStack's diffing.
    private static let livePartialID = "live-partial"

    private var historyScroll: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.history) { entry in
                        Text(entry.text)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(entry.id)
                    }
                    // Live partial: rendered inline as the trailing entry
                    // so the user reads the transcript building up in real
                    // time. Brighter than finalized history to signal
                    // "still being decoded — may change".
                    if !vm.currentCaption.isEmpty {
                        Text(vm.currentCaption)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(Self.livePartialID)
                    }
                }
                .padding(20)
                .onChange(of: vm.history.count) { _, _ in
                    if let last = vm.history.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: vm.currentCaption) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    // No animation here — the partial updates many times a
                    // second and animating each scroll would jitter badly.
                    proxy.scrollTo(Self.livePartialID, anchor: .bottom)
                }
            }
        }
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
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.menu)
            .disabled(isEngineSwitchDisabled)
            .help("Pick the live-captions engine. Each one downloads its model on first use.")
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
