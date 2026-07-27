import Foundation

/// CPU policy for the ONNX-backed streaming engines.
///
/// SOLID:
/// - **SRP**: answers "how many threads should sherpa-onnx use here" and
///   nothing else.
///
/// The sherpa recognizers previously passed a literal `numThreads: 1`, which
/// is also the wrapper's default — so the explicit argument communicated no
/// decision and had no comment justifying it. This type replaces that with a
/// value derived from the machine, and records how it was chosen.
public enum ASRComputeBudget {

    /// Performance cores, falling back to a conservative guess.
    public static var performanceCoreCount: Int {
        var count: Int = 0
        var size = MemoryLayout<Int>.size
        // `hw.perflevel0` is the performance cluster on Apple Silicon. It is
        // absent on Intel, where all cores are equivalent.
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return count
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    /// Intra-op thread count for the streaming sherpa-onnx recognizers.
    ///
    /// Measured on a 4-P-core Apple Silicon machine, Zipformer zh-XLarge
    /// int8, 30 s of audio, best of two runs:
    ///
    ///     threads   wall     RTFx
    ///     1         6.11 s    4.9
    ///     2         3.92 s    7.6   (+55%)
    ///     4         3.38 s    8.9   (+17% over 2)
    ///
    /// Two is chosen over four deliberately. The benchmark feeds the audio in
    /// one batch, which favours wide parallelism; the live path decodes
    /// 20–40 ms chunks, where per-chunk synchronisation eats most of that
    /// remaining 17% while the extra threads compete with the capture thread
    /// and the UI. Two captures the large win without that trade.
    ///
    /// Note the absolute numbers: at one thread this engine ran under 5×
    /// realtime here. On a slower machine that is close enough to realtime
    /// that the engine starts dropping audio — so constrained machines get
    /// two threads as well. Falling behind is the expensive failure, and this
    /// is a CPU decision, not a memory one.
    public static var sherpaThreadCount: Int {
        min(2, performanceCoreCount)
    }
}
