import Foundation

/// Centralized constants — eliminates all magic numbers and strings.
public enum Constants {

    // MARK: - Audio Processing

    public static let defaultSampleRate = 16_000       // Hz
    public static let defaultAudioChannels = 1         // Mono
    public static let chunkDurationSeconds = 120.0     // Seconds per ASR chunk
    public static let overlapDurationSeconds = 15.0    // Overlap between chunks
    public static let minAudioFileSize = 1_000         // Bytes; below this is treated as silence

    // MARK: - ASR

    public static let localAttentionContextSize = 256

    // MARK: - Translation Batch

    public static let defaultMaxCharsPerBatch = 1_200
    public static let defaultMaxEntriesPerBatch = 100

    /// Separator used between entries when sending to Google Translate.
    public static let batchSeparator = "\u{1F538}\u{1F538}\u{1F538}"                     // 🔸🔸🔸
    public static let batchSeparatorWithNewlines = "\n\u{1F538}\u{1F538}\u{1F538}\n"

    /// Separator used between entries when sending to OpenAI.
    public static let percentSeparator = "%%"
    public static let percentSeparatorWithNewlines = "\n%%\n"

    /// Fallback separators tried in order when the primary separator isn't found in a response.
    public static let alternateSeparators = [
        "\n\u{1F538}\u{1F538}\u{1F538}\n",
        "\u{1F538}\u{1F538}\u{1F538}",
        "\n\u{1F538}\u{1F538}\n",
        "\u{1F538}\u{1F538}",
        "\n",
    ]

    // MARK: - API

    public static let defaultOpenAIBaseURL = "https://api.openai.com"
    public static let defaultOpenAIModel = "gpt-4.1-nano"
    public static let defaultMaxRetries = 3
    public static let defaultRetryBaseDelay: TimeInterval = 1.0
    public static let defaultRetryMaxDelay: TimeInterval = 60.0
    public static let apiTimeoutSeconds: TimeInterval = 300

    // MARK: - Progress Milestones (0–100)

    public static let progressAudioExtractionStart = 0
    public static let progressAudioExtractionEnd = 10
    public static let progressModelInitEnd = 20
    public static let progressRecognitionEnd = 70
    public static let progressTranslationStart = 72
    public static let progressTranslationEnd = 80
    public static let progressVideoSynthesisStart = 80
    public static let progressVideoSynthesisEnd = 100

    // MARK: - FFmpeg / Video

    public static let ffmpegSubtitleFontSize = 16
    public static let ffmpegQualityParam = 40          // VideoToolbox quality
    public static let audioExtractionTimeout: TimeInterval = 300
    public static let videoSynthesisTimeout: TimeInterval = 600
    public static let audioCheckTimeout: TimeInterval = 60

    // MARK: - File Paths

    public static let configDirName = "Scribe"
    public static let configFileName = "config.json"
    public static let audioFileSuffix = "_audio.wav"
    public static let englishSubtitleSuffix = "_en.srt"
    public static let bilingualSubtitleSuffix = "_bi.srt"
    public static let outputVideoSuffix = "_subtitled"

    /// Well-known FFmpeg install locations on macOS.
    /// ffmpeg-full (with libass) is preferred over the basic ffmpeg.
    public static let ffmpegPaths = [
        "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg",  // Homebrew ffmpeg-full (has libass)
        "/opt/homebrew/bin/ffmpeg",                   // Homebrew Apple Silicon
        "/usr/local/bin/ffmpeg",                      // Homebrew Intel
        "/usr/bin/ffmpeg",                            // System default
    ]

    // MARK: - Default Translation Prompt

    public static let defaultTranslationPrompt = """
        You are a professional Chinese native translator who needs to fluently translate text into Chinese.

        ## Translation Rules
        1. Output only the translated content, without explanations or additional content (such as "Here's the translation:" or "Translation as follows:")
        2. The returned translation must maintain exactly the same number of paragraphs and format as the original text
        3. For content that should not be translated (such as proper nouns, code, etc.), keep the original text.
        4. If input contains %%, use %% in your output, if input has no %%, don't use %% in your output

        ## OUTPUT FORMAT:
        - **Single paragraph input** → Output translation directly (no separators, no extra text)
        - **Multi-paragraph input** → Use %% as paragraph separator between translations
        """
}
