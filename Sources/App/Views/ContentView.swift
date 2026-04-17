import SwiftUI
import Domain

/// Main application window with native toolbar and materials.
struct ContentView: View {
    @State private var viewModel = ProcessingViewModel()

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

    // MARK: - States

    private var emptyState: some View {
        DropAreaView { urls in
            viewModel.addVideos(urls: urls)
        }
    }

    private var videoList: some View {
        VStack(spacing: 0) {
            DropAreaView(compact: true) { urls in
                viewModel.addVideos(urls: urls)
            }
            .frame(height: 48)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            List {
                ForEach(viewModel.videoItems) { item in
                    VideoItemView(item: item)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            Button("Remove from Queue") {
                                viewModel.removeVideo(item)
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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

        ToolbarItem(placement: .secondaryAction) {
            Button {
                viewModel.clearCompleted()
            } label: {
                Label("Clear Completed", systemImage: "trash")
            }
            .disabled(viewModel.isProcessing || viewModel.videoItems.allSatisfy { $0.state == .queued })
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
}
