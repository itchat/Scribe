import Foundation
import Protocols

/// Bridges progress reports from any thread onto the main actor, merging
/// reports that arrive faster than the main actor drains them.
///
/// SOLID:
/// - **SRP**: only coalesces and delivers. What the values mean, and which
///   view shows them, belongs to the `apply` closure.
/// - **DIP**: producers see `ProgressReporting`; the UI side is a closure,
///   so this is testable without a `VideoItem`.
///
/// The bridge it replaces spawned one `Task { @MainActor }` per report.
/// Unstructured tasks carry no ordering guarantee, so a late-starting task
/// could land an older percent over a newer one, and a busy producer queued
/// one task per report. Here at most one delivery is pending at a time and
/// it always carries the latest values, so order cannot invert and the
/// main-actor work is bounded by how often it runs, not by how often
/// producers report.
final class CoalescingProgressReporter: Protocols.ProgressReporting, @unchecked Sendable {

    /// Receives the latest progress and/or status. `nil` means "unchanged
    /// since the previous delivery".
    typealias Apply = @MainActor (_ progress: Int?, _ status: String?) -> Void

    private let apply: Apply

    // `lock` guards everything below.
    private let lock = NSLock()
    private var pendingProgress: Int?
    private var pendingStatus: String?
    private var deliveryScheduled = false

    init(apply: @escaping Apply) {
        self.apply = apply
    }

    func reportProgress(_ percent: Int) {
        enqueue { $0.pendingProgress = percent }
    }

    func reportStatus(_ message: String) {
        enqueue { $0.pendingStatus = message }
    }

    private func enqueue(_ write: (CoalescingProgressReporter) -> Void) {
        lock.lock()
        write(self)
        let needsDelivery = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()

        guard needsDelivery else { return }
        Task { @MainActor in self.deliver() }
    }

    @MainActor
    private func deliver() {
        lock.lock()
        let progress = pendingProgress
        let status = pendingStatus
        pendingProgress = nil
        pendingStatus = nil
        deliveryScheduled = false
        lock.unlock()

        apply(progress, status)
    }
}
