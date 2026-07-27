import Testing
import Foundation
@testable import Infrastructure

/// Guards the machine-relative limits that replaced hard-coded constants.
///
/// These are properties of the policy, not of the host, so they hold on any
/// machine the suite runs on.
@Suite("MemoryBudget")
struct MemoryBudgetTests {

    @Test("Reports a plausible physical memory size")
    func physicalMemoryIsSane() {
        #expect(MemoryBudget.physicalMemoryGB > 0.5)
        #expect(MemoryBudget.physicalMemoryGB < 4096)
    }

    /// The old fixed value. Scaling must never exceed it, or a large machine
    /// would regress relative to the previous behaviour.
    @Test("MLX cache never exceeds the previous fixed 512 MB ceiling")
    func cacheLimitRespectsCeiling() {
        #expect(MemoryBudget.mlxCacheLimitBytes <= 512 * 1024 * 1024)
        #expect(MemoryBudget.mlxCacheLimitBytes > 0)
    }

    /// One sixteenth of physical memory, so the cache stays a small slice of
    /// the machine rather than a fixed fraction of an 8 GB one.
    @Test("MLX cache is at most a sixteenth of physical memory")
    func cacheLimitScalesWithMachine() {
        #expect(UInt64(MemoryBudget.mlxCacheLimitBytes) <= MemoryBudget.physicalMemory / 16)
    }

    @Test("Constrained classification matches the documented threshold")
    func constrainedMatchesThreshold() {
        #expect(MemoryBudget.isConstrained == (MemoryBudget.physicalMemoryGB <= MemoryBudget.constrainedThresholdGB))
    }

    @Test("Live buffer ceiling is bounded and smaller when constrained")
    func liveBufferCeiling() {
        let seconds = MemoryBudget.maxLiveBufferSeconds
        #expect(seconds >= 10 && seconds <= 60)
        if MemoryBudget.isConstrained {
            #expect(seconds <= 20)
        }
    }

    /// A model needing more than the machine has must never read as a
    /// comfortable fit.
    @Test("Oversized models are not comfortable")
    func oversizedModelsRejected() {
        #expect(!MemoryBudget.isComfortable(modelBytes: MemoryBudget.physicalMemory))
        #expect(!MemoryBudget.isComfortable(modelBytes: MemoryBudget.physicalMemory * 2))
    }

    @Test("A tiny model is always comfortable")
    func tinyModelsAccepted() {
        #expect(MemoryBudget.isComfortable(modelBytes: 1024 * 1024))
    }

    @Test("Summary mentions the tier so bug reports are diagnosable")
    func summaryIsInformative() {
        let summary = MemoryBudget.summary
        #expect(summary.contains("GB physical"))
        #expect(summary.contains(MemoryBudget.isConstrained ? "constrained" : "unconstrained"))
    }
}

@Suite("ASRComputeBudget")
struct ASRComputeBudgetTests {

    @Test("Reports at least one performance core")
    func performanceCores() {
        #expect(ASRComputeBudget.performanceCoreCount >= 1)
    }

    /// Two threads measured ~55% faster than one on the streaming Zipformer;
    /// the cap keeps the decoder from monopolising the performance cluster.
    @Test("Sherpa thread count stays within the measured sweet spot")
    func sherpaThreads() {
        let threads = ASRComputeBudget.sherpaThreadCount
        #expect(threads >= 1)
        #expect(threads <= 2)
        #expect(threads <= ASRComputeBudget.performanceCoreCount)
    }
}
