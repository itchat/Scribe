import Foundation

/// Which translation backend to use.
public enum TranslationEngine: String, Codable, Sendable {
    case openAI = "OpenAI"
    case google = "Google"
}

/// Options that control how a video is processed.
public struct ProcessingOptions: Sendable {
    public let skipTranslation: Bool
    public let skipSubtitleBurning: Bool
    public let translationEngine: TranslationEngine

    public init(
        skipTranslation: Bool = false,
        skipSubtitleBurning: Bool = false,
        translationEngine: TranslationEngine = .openAI
    ) {
        self.skipTranslation = skipTranslation
        self.skipSubtitleBurning = skipSubtitleBurning
        self.translationEngine = translationEngine
    }
}

/// The outcome status of video processing.
public enum ProcessingStatus: Sendable {
    case completed
    case skipped(reason: String)
    case failed(ScribeError)
}

/// The result of processing a single video file.
public struct ProcessingResult: Sendable {
    public let status: ProcessingStatus
    public let outputVideoURL: URL?
    public let subtitleURL: URL?
    public let originalSubtitleURL: URL?

    public init(
        status: ProcessingStatus,
        outputVideoURL: URL? = nil,
        subtitleURL: URL? = nil,
        originalSubtitleURL: URL? = nil
    ) {
        self.status = status
        self.outputVideoURL = outputVideoURL
        self.subtitleURL = subtitleURL
        self.originalSubtitleURL = originalSubtitleURL
    }

    /// Whether processing completed successfully.
    public var isSuccess: Bool {
        if case .completed = status { return true }
        return false
    }
}
