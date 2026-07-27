import Foundation
import Dispatch
import os

/// Watches the system memory-pressure signal and reports level changes.
///
/// SOLID:
/// - **SRP**: owns only the dispatch source and its lifetime. It decides
///   nothing about *what* to free — callers supply that.
/// - **DIP**: consumers depend on the `Level` enum and a callback, not on
///   `DispatchSource`.
///
/// Added because nothing in the app previously observed memory pressure at
/// all: on a machine under strain, the MLX scratch cache and the live audio
/// buffer kept their allocations until their own timers happened to fire.
public final class MemoryPressureMonitor: @unchecked Sendable {

    public enum Level: Sendable {
        /// The system wants memory back; drop caches.
        case warning
        /// The system is desperate; drop everything discardable.
        case critical
    }

    private let logger = Logger(subsystem: "com.scribe", category: "memory.pressure")
    private let queue = DispatchQueue(label: "scribe.memory-pressure")
    private var source: (any DispatchSourceMemoryPressure)?

    public init() {}

    /// Begin observing. Idempotent — a second call replaces the handler.
    ///
    /// The handler runs on a private serial queue, so hop to whatever
    /// isolation you need inside it.
    public func start(onPressure: @escaping @Sendable (Level) -> Void) {
        stop()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, let data = self.source?.data else { return }
            let level: Level = data.contains(.critical) ? .critical : .warning
            self.logger.notice("Memory pressure: \(String(describing: level), privacy: .public)")
            onPressure(level)
        }
        source.resume()
        self.source = source
    }

    /// Stop observing. Safe to call when not started.
    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        source?.cancel()
    }
}
