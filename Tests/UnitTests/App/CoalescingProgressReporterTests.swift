import Testing
import Foundation
@testable import App

/// Collects deliveries on the main actor.
@MainActor
private final class DeliveryLog {
    var deliveries = 0
    var progress: Int?
    var status: String?

    func record(_ p: Int?, _ s: String?) {
        deliveries += 1
        if let p { progress = p }
        if let s { status = s }
    }
}

@MainActor
@Suite("CoalescingProgressReporter")
struct CoalescingProgressReporterTests {

    /// Let queued main-actor deliveries run, up to a deadline.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    @Test("Reports made while the main actor is busy land as one delivery of the latest values")
    func coalescesWhileMainActorBusy() async {
        let log = DeliveryLog()
        let reporter = CoalescingProgressReporter { p, s in log.record(p, s) }

        // The burst runs on the main actor without suspending, so no
        // delivery can run until it ends — the situation in which the old
        // bridge piled up one task per report.
        for i in 0 ... 10_000 {
            reporter.reportProgress(i % 101)
            reporter.reportStatus("step \(i)")
        }
        #expect(log.deliveries == 0)

        await waitUntil { log.deliveries > 0 }
        // Give any (incorrect) extra deliveries a chance to show up.
        for _ in 0 ..< 10 { await Task.yield() }

        #expect(log.deliveries == 1, "20 002 reports must coalesce into one delivery")
        #expect(log.progress == 10_000 % 101)
        #expect(log.status == "step 10000")
    }

    @Test("Reports from another thread always settle on the last value")
    func lastReportWinsAcrossThreads() async {
        let log = DeliveryLog()
        let reporter = CoalescingProgressReporter { p, s in log.record(p, s) }

        await Task.detached {
            for i in 0 ... 10_000 {
                reporter.reportProgress(i % 101)
                reporter.reportStatus("step \(i)")
            }
        }.value

        await waitUntil { log.status == "step 10000" }

        // With one task per report there was no ordering guarantee, so an
        // older value could be applied last.
        #expect(log.status == "step 10000")
        #expect(log.progress == 10_000 % 101)
    }

    @Test("Progress and status coalesce independently")
    func independentFields() async {
        let log = DeliveryLog()
        let reporter = CoalescingProgressReporter { p, s in log.record(p, s) }

        reporter.reportStatus("only status")
        await waitUntil { log.deliveries > 0 }
        #expect(log.status == "only status")
        #expect(log.progress == nil, "an untouched field is delivered as nil")

        reporter.reportProgress(42)
        await waitUntil { log.progress == 42 }
        #expect(log.status == "only status")
    }

    @Test("Reports after a delivery schedule a new one")
    func reschedulesAfterDelivery() async {
        let log = DeliveryLog()
        let reporter = CoalescingProgressReporter { p, s in log.record(p, s) }

        reporter.reportProgress(1)
        await waitUntil { log.progress == 1 }
        reporter.reportProgress(2)
        await waitUntil { log.progress == 2 }

        #expect(log.progress == 2)
        #expect(log.deliveries == 2)
    }
}
