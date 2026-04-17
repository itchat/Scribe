import Foundation
import Domain
import Protocols

/// Orchestrates the 4-step video processing pipeline.
///
/// DIP: All dependencies are injected via constructor — no defaults, no singletons.
/// The Composition Root (App layer) is responsible for assembling concrete implementations.
///
/// Steps:
/// 1. Extract audio (0-10%)
/// 2. Speech recognition (10-70%)
/// 3. Translate subtitles (70-80%) — optional
/// 4. Burn subtitles into video (80-100%) — optional
public final class VideoPipeline: @unchecked Sendable {

    private let videoURL: URL
    private let cacheDir: URL
    private let options: ProcessingOptions

    private let audioExtractor: any AudioExtracting
    private let speechRecognizer: any SpeechRecognizing
    private let translator: any SubtitleTranslating
    private let videoComposer: any VideoComposing
    private let subtitleFormatter: any SubtitleFormatting
    private let progress: (any Protocols.ProgressReporting)?

    public init(
        videoURL: URL,
        cacheDir: URL,
        options: ProcessingOptions,
        audioExtractor: any AudioExtracting,
        speechRecognizer: any SpeechRecognizing,
        translator: any SubtitleTranslating,
        videoComposer: any VideoComposing,
        subtitleFormatter: any SubtitleFormatting,
        progress: (any Protocols.ProgressReporting)?
    ) {
        self.videoURL = videoURL
        self.cacheDir = cacheDir
        self.options = options
        self.audioExtractor = audioExtractor
        self.speechRecognizer = speechRecognizer
        self.translator = translator
        self.videoComposer = videoComposer
        self.subtitleFormatter = subtitleFormatter
        self.progress = progress
    }

    // MARK: - Process

    public func process() async -> ProcessingResult {
        let baseName = videoURL.deletingPathExtension().lastPathComponent
        let videoDir = videoURL.deletingLastPathComponent()
        let audioURL = cacheDir.appendingPathComponent("\(baseName)\(Constants.audioFileSuffix)")
        let srtURL = videoDir.appendingPathComponent("\(baseName)\(Constants.englishSubtitleSuffix)")

        do {
            // 1. Extract audio (0–10%)
            progress?.reportStatus("Extracting audio...")
            progress?.reportProgress(Constants.progressAudioExtractionStart)
            try await audioExtractor.extract(from: videoURL, to: audioURL)
            progress?.reportProgress(Constants.progressAudioExtractionEnd)

            // 2. Speech recognition (10–70%)
            progress?.reportStatus("Recognizing speech...")
            let transcription = try await speechRecognizer.transcribe(audioAt: audioURL, progress: progress)
            progress?.reportProgress(Constants.progressRecognitionEnd)

            // Format transcription into subtitle entries
            let entries = subtitleFormatter.format(result: transcription)

            // Write English SRT
            let srtContent = SRTWriter.write(entries)
            try srtContent.write(to: srtURL, atomically: true, encoding: String.Encoding.utf8)

            // If skip translation, stop here
            if options.skipTranslation {
                progress?.reportStatus("Recognition completed — translation skipped")
                progress?.reportProgress(Constants.progressVideoSynthesisEnd)
                return ProcessingResult(
                    status: .completed,
                    subtitleURL: srtURL,
                    originalSubtitleURL: srtURL
                )
            }

            // 3. Translate subtitles (70–80%)
            progress?.reportStatus("Translating subtitles...")
            progress?.reportProgress(Constants.progressTranslationStart)
            let translatedEntries = try await translator.translate(entries: entries)
            progress?.reportProgress(Constants.progressTranslationEnd)

            // Write bilingual SRT
            let bilingualURL = videoDir.appendingPathComponent("\(baseName)\(Constants.bilingualSubtitleSuffix)")
            let bilingualContent = SRTWriter.write(translatedEntries, bilingual: true)

            guard !bilingualContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else {
                progress?.reportStatus("Empty subtitles, skipping synthesis")
                progress?.reportProgress(Constants.progressVideoSynthesisEnd)
                return ProcessingResult(status: .skipped(reason: "Empty subtitles"))
            }

            try bilingualContent.write(to: bilingualURL, atomically: true, encoding: String.Encoding.utf8)

            // If skip burning, stop here
            if options.skipSubtitleBurning {
                progress?.reportStatus("Processing completed! (subtitle burning skipped)")
                progress?.reportProgress(Constants.progressVideoSynthesisEnd)
                return ProcessingResult(
                    status: .completed,
                    subtitleURL: bilingualURL,
                    originalSubtitleURL: srtURL
                )
            }

            // 4. Burn subtitles into video (80–100%)
            progress?.reportStatus("Synthesizing video...")
            let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
            let ext = videoURL.pathExtension
            let outputURL = videoDir.appendingPathComponent("\(baseName)\(Constants.outputVideoSuffix)_\(timestamp).\(ext)")

            try await videoComposer.compose(
                video: videoURL,
                subtitles: bilingualURL,
                output: outputURL,
                progress: progress
            )

            progress?.reportStatus("Processing completed!")
            progress?.reportProgress(Constants.progressVideoSynthesisEnd)

            return ProcessingResult(
                status: .completed,
                outputVideoURL: outputURL,
                subtitleURL: bilingualURL,
                originalSubtitleURL: srtURL
            )

        } catch {
            return ProcessingResult(
                status: .failed(
                    (error as? ScribeError)
                    ?? .audioExtractionFailed(underlying: error)
                )
            )
        }
    }
}
