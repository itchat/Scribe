import Foundation

/// Which offline ASR engine the burn pipeline uses to transcribe audio
/// extracted from a video file.
///
/// SOLID:
/// - **OCP**: Future engines get a new case + a new `SpeechRecognizing`
///   conformer; existing engines and the pipeline assembly stay untouched.
/// - **DIP**: The pipeline depends on `SpeechRecognizing`; this enum only
///   selects which conformer to instantiate at the composition root.
public enum OfflineASREngine: String, Codable, Sendable, CaseIterable {

    /// FluidAudio Parakeet v2 — English-only, ANE-accelerated via CoreML.
    /// Default since it's the fastest for the dominant English use case.
    case parakeetV2 = "Parakeet v2"

    /// Qwen3-ASR 0.6B (4-bit MLX) — multilingual incl. zh-en code-switching.
    /// Faster than 1.7B; lower accuracy.
    /// Model: `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` on HuggingFace.
    case qwen3_0_6B = "Qwen3 ASR 0.6B"

    /// Qwen3-ASR 1.7B (4-bit MLX) — same coverage as 0.6B with higher
    /// accuracy at ~2.86x the runtime.
    /// Model: `aufklarer/Qwen3-ASR-1.7B-MLX-4bit` on HuggingFace.
    case qwen3_1_7B = "Qwen3 ASR 1.7B"

    /// Human-readable label shown in the Settings picker. Includes a hint
    /// about language coverage so users can pick without reading docs.
    public var displayName: String {
        switch self {
        case .parakeetV2:  return "Parakeet v2 (English, fastest)"
        case .qwen3_0_6B:  return "Qwen3 ASR 0.6B (Multilingual incl. zh+en, fast)"
        case .qwen3_1_7B:  return "Qwen3 ASR 1.7B (Multilingual incl. zh+en, accurate)"
        }
    }

    /// Approximate first-run download size shown in the UI. Qwen3 totals
    /// include the ~342 MB Qwen3-ForcedAligner-0.6B (4-bit MLX) download
    /// used for word-level acoustic timestamps; the aligner is shared
    /// across both 0.6B and 1.7B sizes.
    public var downloadSizeLabel: String {
        switch self {
        case .parakeetV2:  return "~1.2 GB"
        case .qwen3_0_6B:  return "~684 MB (incl. word-aligner)"
        case .qwen3_1_7B:  return "~1.04 GB (incl. word-aligner)"
        }
    }
}
