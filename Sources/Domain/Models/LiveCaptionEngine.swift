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

    public var displayName: String {
        switch self {
        case .nemotron:             return "Nemotron 0.6B (English, fast)"
        case .zipformerZhXLarge:    return "Zipformer zh-XLarge (Mandarin-focused, larger)"
        case .paraformerTrilingual: return "Paraformer zh-yue-en (Mandarin + Cantonese + English)"
        }
    }

    /// Approximate first-run download size shown in the UI.
    public var downloadSizeLabel: String {
        switch self {
        case .nemotron:             return "~700 MB"
        case .zipformerZhXLarge:    return "~570 MB"
        case .paraformerTrilingual: return "~999 MB"
        }
    }
}
