import Testing
import Foundation
@testable import Core
@testable import Protocols

/// Records every value it is given, in order.
private final class RecordingReporter: Protocols.ProgressReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _progress: [Int] = []
    private var _statuses: [String] = []

    var progress: [Int] { lock.lock(); defer { lock.unlock() }; return _progress }
    var statuses: [String] { lock.lock(); defer { lock.unlock() }; return _statuses }

    func reportProgress(_ percent: Int) { lock.lock(); _progress.append(percent); lock.unlock() }
    func reportStatus(_ message: String) { lock.lock(); _statuses.append(message); lock.unlock() }
}

@Suite("StageProgressReporter")
struct StageProgressReporterTests {

    @Test("Stage-local 0–100 maps onto the stage's slice of the bar")
    func mapsOntoRange() {
        let base = RecordingReporter()
        let stage = StageProgressReporter(base: base, range: 80...100)

        stage.reportProgress(0)
        stage.reportProgress(50)
        stage.reportProgress(100)

        #expect(base.progress == [80, 90, 100])
    }

    @Test("A stage reporting from zero never moves the bar below its start")
    func neverRegressesBelowStart() {
        // The composer reports raw 0–99. Before this mapping the bar fell
        // from 80 back to single digits at the start of every burn.
        let base = RecordingReporter()
        let stage = StageProgressReporter(base: base, range: 80...100)

        for p in [0, 3, 17, 64, 99] { stage.reportProgress(p) }

        #expect(base.progress.allSatisfy { $0 >= 80 })
        #expect(base.progress == base.progress.sorted())
    }

    @Test("Out-of-range input is clamped")
    func clamps() {
        let base = RecordingReporter()
        let stage = StageProgressReporter(base: base, range: 10...70)

        stage.reportProgress(-5)
        stage.reportProgress(250)

        #expect(base.progress == [10, 70])
    }

    @Test("Status messages pass through unchanged")
    func passesStatus() {
        let base = RecordingReporter()
        StageProgressReporter(base: base, range: 10...70).reportStatus("Loading…")
        #expect(base.statuses == ["Loading…"])
    }

    @Test("A nil base is a no-op")
    func nilBase() {
        let stage = StageProgressReporter(base: nil, range: 0...100)
        stage.reportProgress(50)
        stage.reportStatus("ignored")
    }
}

@Suite("ProgressThrottle")
struct ProgressThrottleTests {

    @Test("Yields only when the whole percent changes")
    func yieldsOnChange() {
        var throttle = ProgressThrottle()
        #expect(throttle.percent(for: 0.0) == 0)
        #expect(throttle.percent(for: 0.004) == nil)
        #expect(throttle.percent(for: 0.009) == nil)
        #expect(throttle.percent(for: 0.01) == 1)
        #expect(throttle.percent(for: 0.015) == nil)
        #expect(throttle.percent(for: 1.0) == 100)
    }

    @Test("A two-hour file's per-chunk loop reports at most ~100 times")
    func boundsReportCount() {
        // Mirrors the Qwen3 offline loop: one call per 512-sample chunk of
        // 16 kHz audio. This is the regression the throttle exists for.
        let totalSamples = 2 * 3600 * 16_000
        let chunk = 512
        var throttle = ProgressThrottle()
        var reports = 0
        var offset = 0
        while offset < totalSamples {
            offset = min(offset + chunk, totalSamples)
            if throttle.percent(for: Double(offset) / Double(totalSamples)) != nil {
                reports += 1
            }
        }
        #expect(reports <= 101)
        #expect(reports >= 100)
    }

    @Test("Fractions outside 0…1 are clamped")
    func clamps() {
        var throttle = ProgressThrottle()
        #expect(throttle.percent(for: -1) == 0)
        #expect(throttle.percent(for: 7) == 100)
    }
}
