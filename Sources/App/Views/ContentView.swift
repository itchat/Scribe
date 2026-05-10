import SwiftUI
import UniformTypeIdentifiers
import Domain

/// Main application window with native toolbar and materials.
struct ContentView: View {
    @State private var viewModel = ProcessingViewModel()
    @State private var selectedItemID: VideoItem.ID?
    @State private var isWindowDropTargeted = false

    var body: some View {
        Group {
            if viewModel.videoItems.isEmpty {
                emptyState
            } else {
                videoList
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .navigationTitle("Scribe")
        .toolbar { toolbarContent }
        // The whole window is one big drop target — the user can drop
        // additional videos anywhere over the empty placeholder OR over
        // the queued list itself, with a single visual highlight at the
        // window edge instead of a dedicated drop bar.
        .overlay(alignment: .top) { dropHighlight }
        .dropDestination(for: URL.self) { urls, _ in
            let videoURLs = ContentView.filterVideoURLs(urls)
            guard !videoURLs.isEmpty else { return false }
            viewModel.addVideos(urls: videoURLs)
            return true
        } isTargeted: { targeted in
            isWindowDropTargeted = targeted
        }
        .inspector(isPresented: $viewModel.showSettings) {
            SettingsInspector(
                config: viewModel.currentConfig,
                onSave: { viewModel.updateConfig($0) }
            )
            .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
        }
        .sheet(isPresented: $viewModel.showModelDownload) {
            ModelDownloadSheet(
                isDownloading: viewModel.isDownloadingModel,
                progress: viewModel.modelDownloadProgress,
                isReady: viewModel.isModelReady,
                onDownload: { viewModel.downloadModel() }
            )
        }
        .onAppear {
            viewModel.loadConfig()
            viewModel.checkModelStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openVideoFiles)) { notification in
            if let urls = notification.userInfo?["urls"] as? [URL] {
                viewModel.addVideos(urls: urls)
            }
        }
        .toasts($viewModel.toasts)
    }

    /// Filename extensions accepted by the drop target. Keep in sync with
    /// `ProcessingViewModel.addVideos` validation.
    private static let videoExtensions: Set<String> = ["mp4", "avi", "mov", "mkv", "flv", "wmv"]

    private static func filterVideoURLs(_ urls: [URL]) -> [URL] {
        urls.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
    }

    // MARK: - States

    private var emptyState: some View {
        DropAreaView { urls in
            viewModel.addVideos(urls: urls)
        }
    }

    /// List with single-select; the selected item's ID drives the toolbar
    /// "Remove Selected" button and the ⌫/Delete keyboard shortcut.
    private var videoList: some View {
        List(selection: $selectedItemID) {
            ForEach(viewModel.videoItems) { item in
                VideoItemView(item: item)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .tag(item.id)
                    .contextMenu {
                        Button("Remove from Queue") {
                            viewModel.removeVideo(item)
                            if selectedItemID == item.id { selectedItemID = nil }
                        }
                        .disabled(item.state == .processing)
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Faint blue stroke around the window when a drop is in flight.
    /// Communicates "you can drop here" without taking up a dedicated row.
    @ViewBuilder
    private var dropHighlight: some View {
        if isWindowDropTargeted {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor, lineWidth: 3)
                .padding(4)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                viewModel.showModelDownload = true
            } label: {
                Label("ASR Model", systemImage: "waveform.badge.mic")
                    .labelStyle(.iconOnly)
            }
            .help(viewModel.isModelReady ? "ASR model ready" : "ASR model not downloaded")
        }

        // Remove selected — replaces "Clear Completed" since it covers a
        // strictly larger workflow (drag any item out at any state, hit ⌫).
        // Disabled while the selection is mid-process so the user can't
        // accidentally orphan an in-flight pipeline.
        ToolbarItem(placement: .secondaryAction) {
            Button(role: .destructive) {
                removeSelected()
            } label: {
                Label("Remove Selected", systemImage: "trash")
            }
            .disabled(!isSelectionRemovable)
            .keyboardShortcut(.delete, modifiers: [])
            .help(isSelectionRemovable
                  ? "Remove the selected item from the queue (⌫)"
                  : "Can't remove an item while it's processing")
        }

        ToolbarItem(placement: .secondaryAction) {
            Button {
                viewModel.clearCompleted()
            } label: {
                Label("Clear Completed", systemImage: "checkmark.circle")
            }
            .disabled(viewModel.isProcessing || viewModel.videoItems.allSatisfy { $0.state != .completed && $0.state != .failed })
            .help("Remove all completed and failed items")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.showSettings.toggle()
            } label: {
                Label("Settings", systemImage: "sidebar.right")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        // Prominent Start button (stays visible and labeled)
        ToolbarItem(placement: .primaryAction) {
            Button {
                viewModel.startProcessing()
            } label: {
                if viewModel.isProcessing {
                    Label("Processing…", systemImage: "hourglass")
                } else {
                    Label("Start Processing", systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(viewModel.isProcessing || !viewModel.hasVideosToProcess)
            .keyboardShortcut("r", modifiers: .command)
            .help("Start processing queued videos (⌘R)")
        }
    }

    private func removeSelected() {
        guard let id = selectedItemID,
              let item = viewModel.videoItems.first(where: { $0.id == id }) else { return }
        viewModel.removeVideo(item)
        // The view-model refuses to remove .processing items and surfaces a
        // toast; only clear the selection when the row really left the list.
        if !viewModel.videoItems.contains(where: { $0.id == id }) {
            selectedItemID = nil
        }
    }

    /// True when the selected item exists and is in a state that allows
    /// removal — anything except `.processing`.
    private var isSelectionRemovable: Bool {
        guard let id = selectedItemID,
              let item = viewModel.videoItems.first(where: { $0.id == id })
        else { return false }
        return item.state != .processing
    }
}
