import SwiftUI
import Foundation
import AVFoundation
import Domain
import Protocols
import Core
import Infrastructure

// MARK: - Video Item

/// Represents the processing state of a single video file.
@Observable
@MainActor
final class VideoItem: Identifiable {
    let id = UUID()
    let url: URL
    var fileName: String { url.lastPathComponent }
    var progress: Int = 0
    var status: String = "Waiting…"
    var state: VideoItemState = .queued
    var result: ProcessingResult?

    // Metadata
    var thumbnail: NSImage?
    var duration: TimeInterval?
    var resolution: String?
    var fileSize: Int64?

    init(url: URL) {
        self.url = url
        Task { @MainActor in await self.loadMetadata() }
    }

    var fileSizeFormatted: String {
        guard let size = fileSize else { return "" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: size)
    }

    var durationFormatted: String {
        guard let d = duration else { return "" }
        let h = Int(d) / 3600
        let m = (Int(d) % 3600) / 60
        let s = Int(d) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func loadMetadata() async {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            self.fileSize = (attrs[.size] as? NSNumber)?.int64Value
        }

        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            self.duration = CMTimeGetSeconds(duration)

            let time = CMTime(seconds: CMTimeGetSeconds(duration) * 0.1, preferredTimescale: 600)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 120, height: 80)
            let cgImage = try await generator.image(at: time).image
            self.thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: 60, height: 40))

            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                self.resolution = "\(Int(size.width))×\(Int(size.height))"
            }
        } catch {
            // Metadata failure is non-fatal
        }
    }
}

enum VideoItemState {
    case queued, processing, completed, failed
}

// MARK: - ProcessingViewModel (thin facade)

/// Coordinates the video processing workflow.
///
/// SRP: Only workflow orchestration — delegates to specialized services:
/// - `ConfigService` — settings persistence
/// - `ASRModelService` — model download & status
/// - `ToastCenter` — transient UI feedback
/// - `SystemNotifier` — system-level notifications
@Observable
@MainActor
final class ProcessingViewModel {

    var videoItems: [VideoItem] = []
    var isProcessing = false
    var showSettings = false
    var showModelDownload = false

    // Injected services
    let configService: ConfigService
    let modelService: ASRModelService
    let toastCenter: ToastCenter
    private let notifier: SystemNotifier
    private let cacheDir: URL

    init(
        configService: ConfigService = ConfigService(),
        modelService: ASRModelService = ASRModelService(),
        toastCenter: ToastCenter = ToastCenter(),
        notifier: SystemNotifier = SystemNotifier(),
        cacheDir: URL? = nil
    ) {
        self.configService = configService
        self.modelService = modelService
        self.toastCenter = toastCenter
        self.notifier = notifier
        self.cacheDir = cacheDir ?? FileManager.default.temporaryDirectory.appendingPathComponent("scribe_cache")
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Config proxies (for SwiftUI binding convenience)

    var currentConfig: AppConfig { configService.config }
    func loadConfig() { configService.load() }
    func updateConfig(_ c: AppConfig) { configService.update(c) }

    // MARK: - Model proxies

    var isModelReady: Bool { modelService.isReady }
    var isDownloadingModel: Bool { modelService.isDownloading }
    var modelDownloadProgress: Double { modelService.downloadProgress }
    func downloadModel() { modelService.download() }
    func checkModelStatus() { modelService.refresh() }

    // MARK: - Toast proxy

    var toasts: [ToastMessage] {
        get { toastCenter.toasts }
        set { toastCenter.toasts = newValue }
    }

    // MARK: - File Management

    func addVideos(urls: [URL]) {
        let validExtensions = ["mp4", "avi", "mov", "mkv", "flv", "wmv"]
        let newItems = urls
            .filter { validExtensions.contains($0.pathExtension.lowercased()) }
            .map { VideoItem(url: $0) }
        videoItems.append(contentsOf: newItems)
        if !newItems.isEmpty {
            toastCenter.show("Added \(newItems.count) video\(newItems.count == 1 ? "" : "s")", kind: .info)
        }
    }

    func removeVideo(_ item: VideoItem) {
        videoItems.removeAll { $0.id == item.id }
    }

    func clearCompleted() {
        videoItems.removeAll { $0.state == .completed || $0.state == .failed }
    }

    var hasVideosToProcess: Bool {
        videoItems.contains { $0.state == .queued }
    }

    // MARK: - Processing

    func startProcessing() {
        guard !isProcessing, hasVideosToProcess else { return }
        isProcessing = true

        Task {
            let startCount = videoItems.filter { $0.state == .queued }.count
            await processQueue()
            isProcessing = false
            modelService.refresh()

            let succeeded = videoItems.filter { $0.state == .completed }.count
            let failed = videoItems.filter { $0.state == .failed }.count
            let summary = "\(succeeded) succeeded, \(failed) failed"

            if failed == 0 {
                toastCenter.show("All \(startCount) videos processed successfully", kind: .success)
            } else {
                toastCenter.show(summary, kind: .error)
            }

            notifier.post(
                title: "Scribe",
                body: "Finished processing \(startCount) video\(startCount == 1 ? "" : "s"): \(summary)"
            )
        }
    }

    private func processQueue() async {
        for item in videoItems where item.state == .queued {
            item.state = .processing
            item.status = "Starting…"
            item.progress = 0

            let reporter = ItemProgressReporter(item: item)
            let pipeline = createPipeline(for: item.url, progress: reporter)
            let result = await pipeline.process()

            item.result = result
            item.progress = 100

            if result.isSuccess {
                item.state = .completed
                item.status = "Completed"
            } else {
                item.state = .failed
                if case .failed(let error) = result.status {
                    item.status = "Failed: \(error.localizedDescription)"
                } else {
                    item.status = "Failed"
                }
            }
        }
    }

    // MARK: - Pipeline Assembly (Composition Root for a single run)

    private func createPipeline(for videoURL: URL, progress: any Protocols.ProgressReporting) -> VideoPipeline {
        let config = configService.config
        let options = ProcessingOptions(
            skipTranslation: config.skipTranslation,
            skipSubtitleBurning: config.skipSubtitleBurning,
            translationEngine: config.translationEngine
        )

        // Translator based on engine selection
        let translator: any SubtitleTranslating = {
            switch config.translationEngine {
            case .google:
                return GoogleTranslator()
            case .openAI:
                let openAI = OpenAITranslator(
                    apiKey: config.apiKey,
                    baseURL: config.baseURL,
                    model: config.model,
                    systemPrompt: config.customPrompt
                )
                return config.enableGoogleFallback
                    ? FallbackTranslator(primary: openAI, fallback: GoogleTranslator())
                    : openAI
            }
        }()

        // FFmpeg components with graceful fallback
        let audioExtractor: any AudioExtracting
        let videoComposer: any VideoComposing
        do {
            audioExtractor = try FFmpegAudioExtractor()
            videoComposer = try FFmpegVideoComposer()
        } catch {
            return VideoPipeline(
                videoURL: videoURL, cacheDir: cacheDir, options: options,
                audioExtractor: FailingAudioExtractor(),
                speechRecognizer: FailingSpeechRecognizer(),
                translator: translator,
                videoComposer: FailingVideoComposer(),
                subtitleFormatter: SubtitleFormatter(),
                progress: progress
            )
        }

        return VideoPipeline(
            videoURL: videoURL, cacheDir: cacheDir, options: options,
            audioExtractor: audioExtractor,
            speechRecognizer: modelService.speechRecognizer,
            translator: translator,
            videoComposer: videoComposer,
            subtitleFormatter: SubtitleFormatter(),
            progress: progress
        )
    }
}

// MARK: - Progress Bridge

private final class ItemProgressReporter: Protocols.ProgressReporting, @unchecked Sendable {
    private let item: VideoItem
    init(item: VideoItem) { self.item = item }

    nonisolated func reportProgress(_ percent: Int) {
        let item = self.item
        Task { @MainActor in item.progress = percent }
    }

    nonisolated func reportStatus(_ message: String) {
        let item = self.item
        Task { @MainActor in item.status = message }
    }
}

// MARK: - Failing stubs (when FFmpeg isn't available)

private struct FailingAudioExtractor: AudioExtracting, Sendable {
    func extract(from videoURL: URL, to outputURL: URL) async throws {
        throw ScribeError.ffmpegNotFound
    }
}

private struct FailingSpeechRecognizer: SpeechRecognizing, Sendable {
    func transcribe(audioAt url: URL, progress: (any Protocols.ProgressReporting)?) async throws -> TranscriptionResult {
        throw ScribeError.modelNotDownloaded
    }
}

private struct FailingVideoComposer: VideoComposing, Sendable {
    func compose(video: URL, subtitles: URL, output: URL, progress: (any Protocols.ProgressReporting)?) async throws {
        throw ScribeError.ffmpegNotFound
    }
}
