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

    /// sherpa-onnx streaming bilingual zh-en Zipformer transducer (2023-02-20
    /// release). Single bilingual decoder with shared BPE+char vocab — handles
    /// intra-utterance Mandarin↔English code-switching natively (e.g.
    /// "今天 deploy 一个 new feature 到 production"). True streaming with
    /// frame-sync online decoding; ~300 ms first-partial latency on
    /// Apple Silicon. ONNX runtime, fully on-device.
    /// See https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html
    case zipformerZhEn = "Zipformer zh-en"

    public var displayName: String {
        switch self {
        case .nemotron:      return "Nemotron 0.6B (English, fast)"
        case .zipformerZhEn: return "Zipformer zh-en (Chinese + English, code-switching)"
        }
    }

    /// Approximate first-run download size shown in the UI.
    public var downloadSizeLabel: String {
        switch self {
        case .nemotron:      return "~700 MB"
        case .zipformerZhEn: return "~342 MB"
        }
    }
}
