import Foundation
import os

/// Machine-relative memory policy for the ASR engines.
///
/// SOLID:
/// - **SRP**: only answers "how much memory may this machine spend on ASR" —
///   it allocates nothing and owns no lifecycle.
/// - **OCP**: engines read the budget instead of hard-coding constants, so a
///   new tier is a change here rather than at every call site.
///
/// Exists because every limit in the ASR path used to be a fixed number
/// chosen on a development machine with plenty of RAM. On an 8 GB M1 — the
/// lowest configuration Scribe targets — a 512 MB scratch cache is ~7% of
/// total system memory held as reclaimable-but-unreclaimed GPU allocation,
/// on top of model weights and the OS.
public enum MemoryBudget {

    private static let logger = Logger(subsystem: "com.scribe", category: "memory.budget")

    /// Total physical memory, in bytes.
    public static var physicalMemory: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// Physical memory in gigabytes, for display and threshold comparisons.
    public static var physicalMemoryGB: Double {
        Double(physicalMemory) / 1_073_741_824
    }

    /// Machines at or below this are treated as memory-constrained.
    public static let constrainedThresholdGB: Double = 8.5

    /// Whether this machine needs the conservative settings.
    ///
    /// The comparison is slightly above 8 so a nominal "8 GB" machine, which
    /// reports a little under 8 × 2^30, still classifies as constrained.
    public static var isConstrained: Bool {
        physicalMemoryGB <= constrainedThresholdGB
    }

    /// Upper bound for MLX's scratch allocation cache.
    ///
    /// One sixteenth of physical memory, clamped to the previous fixed value
    /// so a large machine behaves exactly as before: 512 MB at 16 GB and up,
    /// 256 MB on an 8 GB machine.
    public static var mlxCacheLimitBytes: Int {
        let oneSixteenth = physicalMemory / 16
        let ceiling: UInt64 = 512 * 1024 * 1024
        return Int(min(oneSixteenth, ceiling))
    }

    /// Hard ceiling on the live-capture sample buffer, in seconds of audio.
    ///
    /// The buffer is only self-limiting while ASR keeps up with realtime.
    /// When it falls behind — the expected case for a 1.7B model on an 8 GB
    /// machine — it otherwise grows at 16 kHz × 4 bytes ≈ 64 KB/s, about
    /// 230 MB/hour, with no back-pressure and no ceiling.
    public static var maxLiveBufferSeconds: Double {
        isConstrained ? 20 : 30
    }

    /// Whether a model of the given weight size is a comfortable fit.
    ///
    /// Used to warn rather than to block — the user may know something we
    /// don't (an otherwise idle machine, a short clip).
    public static func isComfortable(modelBytes: UInt64) -> Bool {
        // Weights, plus roughly the same again for activations, KV cache and
        // the scratch pool, should stay under half of physical memory.
        modelBytes * 2 < physicalMemory / 2
    }

    /// One-line description for logs and diagnostics.
    public static var summary: String {
        String(
            format: "%.1f GB physical, %@, MLX cache %d MB, live buffer %.0fs",
            physicalMemoryGB,
            isConstrained ? "constrained" : "unconstrained",
            mlxCacheLimitBytes / (1024 * 1024),
            maxLiveBufferSeconds
        )
    }

    /// Log the resolved budget once, so a bug report says which tier applied.
    public static func logSummary() {
        logger.info("Memory budget: \(summary, privacy: .public)")
    }
}
