import Foundation
import MLX

/// Applies `MemoryBudget`'s limits to MLX's process-global allocator.
///
/// SOLID:
/// - **SRP**: the only place that writes MLX memory settings. `MemoryBudget`
///   decides the numbers; this type applies them.
/// - **DIP**: recognizers call `apply()` instead of each poking
///   `MLX.Memory` with its own idea of the limit.
///
/// The cache limit is process-global, but it used to be set only when Live
/// Captions started a Qwen3 engine. A burn run with Qwen3 that happened
/// before Live Captions ever opened therefore ran with MLX's default cache
/// limit — on an 8 GB machine, exactly the unbounded scratch growth the
/// budget exists to prevent.
public enum MLXMemoryPolicy {

    /// Set the cache limit from `MemoryBudget`. Idempotent.
    ///
    /// Call after a model has loaded, not at launch: MLX initialises its
    /// Metal allocator on first use, and touching it before the metallib is
    /// available faults (see the note on `clearCache` in
    /// `Qwen3ASRStreamingRecognizer.reset()`).
    public static func apply() {
        MLX.Memory.cacheLimit = MemoryBudget.mlxCacheLimitBytes
        MemoryBudget.logSummary()
    }
}
