import Foundation

/// Which streaming ASR engine to use behind the Live Captions window.
///
/// OCP: future engines get a new case + a new `StreamingTranscribing`
/// conformer; existing engines stay untouched. The view model picks an
/// engine via factory function and never branches on the case at runtime.
public enum LiveCaptionEngine: String, Codable, Sendable, CaseIterable {
    /// FluidAudio Nemotron 0.6B (1120 ms chunks). True streaming, ~1.1 s
    /// latency, English-only.
    case nemotron = "Nemotron 0.6B"

    /// sherpa-onnx streaming Zipformer zh xlarge int8 (2025-06-30).
    /// A bigger Mandarin-focused Zipformer transducer than the 2023
    /// bilingual baseline — int8-quantised to ~570 MB. Better Chinese
    /// quality at the cost of weaker English; pick this when the
    /// audio is predominantly Mandarin.
    case zipformerZhXLarge = "Zipformer zh-XLarge"

    /// sherpa-onnx streaming Paraformer trilingual zh-yue-en. Non-
    /// autoregressive Paraformer covers Mandarin, Cantonese, and
    /// English in the same decoder — useful when the speaker mixes
    /// any two of the three. ~999 MB compressed.
    case paraformerTrilingual = "Paraformer zh-yue-en"

    /// Qwen3-ASR 0.6B (MLX 4-bit) driven by Silero VAD segmentation +
    /// per-segment partial refresh every ~1 s. Multilingual end-to-end
    /// LLM-backbone ASR with native punctuation/ITN/code-switching.
    /// Heavier than the Sherpa/Nemotron transducers (runs on GPU via
    /// MLX) but the only option that natively handles mixed Mandarin/
    /// English/Cantonese with punctuation in one model.
    case qwen3ASRSmall = "Qwen3-ASR 0.6B"

    /// Qwen3-ASR 1.7B (MLX 4-bit). Higher quality than 0.6B; pick when
    /// throughput on the target machine is comfortable and accuracy
    /// matters (e.g., dense technical content, accented speakers).
    case qwen3ASRLarge = "Qwen3-ASR 1.7B"

    public var displayName: String {
        switch self {
        case .nemotron:             return "Nemotron 0.6B (English, fast)"
        case .zipformerZhXLarge:    return "Zipformer zh-XLarge (Mandarin-focused, larger)"
        case .paraformerTrilingual: return "Paraformer zh-yue-en (Mandarin + Cantonese + English)"
        case .qwen3ASRSmall:        return "Qwen3-ASR 0.6B (multilingual, punctuation, MLX)"
        case .qwen3ASRLarge:        return "Qwen3-ASR 1.7B (multilingual, higher quality, MLX)"
        }
    }

    /// Approximate first-run download size shown in the UI.
    public var downloadSizeLabel: String {
        switch self {
        case .nemotron:             return "~700 MB"
        case .zipformerZhXLarge:    return "~570 MB"
        case .paraformerTrilingual: return "~999 MB"
        // Qwen3-ASR 4-bit MLX checkpoints + Silero VAD (~40 MB) co-load.
        case .qwen3ASRSmall:        return "~380 MB"
        case .qwen3ASRLarge:        return "~740 MB"
        }
    }

    /// Approximate resident weight size once loaded, in bytes.
    ///
    /// Distinct from `downloadSizeLabel`: what matters for whether a machine
    /// can run an engine is what stays in memory, not what crossed the
    /// network. Used to warn on memory-constrained machines.
    public var approximateResidentBytes: UInt64 {
        switch self {
        case .nemotron:             return 700 * 1_048_576
        case .zipformerZhXLarge:    return 570 * 1_048_576
        case .paraformerTrilingual: return 999 * 1_048_576
        case .qwen3ASRSmall:        return 420 * 1_048_576
        case .qwen3ASRLarge:        return 780 * 1_048_576
        }
    }

    /// Whether this engine runs a large language-model backbone, which costs
    /// far more at runtime than the weights alone (activations, KV cache and
    /// the MLX scratch pool).
    public var isHeavyweight: Bool {
        switch self {
        case .qwen3ASRSmall, .qwen3ASRLarge: return true
        case .nemotron, .zipformerZhXLarge, .paraformerTrilingual: return false
        }
    }
}
