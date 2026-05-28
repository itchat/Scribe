import Testing
import Foundation
@testable import Infrastructure

/// Lifecycle-only tests for `Qwen3ASRStreamingRecognizer` — exercises the
/// start/finish/start dance without ever loading MLX weights. Uses the
/// `testingOverrideLifecycle` actor-internal hooks exposed solely for these
/// tests; in production the lifecycle is identical but model loading is
/// the dominant cost.
///
/// Why this matters: prior to the fix, `start()` early-returned when the
/// models were non-nil, leaving the processing loop dead after a previous
/// `finish()` had cancelled it. The UI showed "listening" but the engine
/// silently emitted nothing on the second start.
@Suite("Qwen3StreamingLifecycle")
struct Qwen3StreamingLifecycleTests {

    @Test("Calling start twice with finish in between re-arms the processing loop")
    func restartAfterFinishRearmsProcessing() async throws {
        let recognizer = Qwen3ASRStreamingRecognizer(size: .b0_6)
        // Pretend the models are already loaded so we can exercise the
        // start/finish/start lifecycle without paying ~500 MB of downloads.
        await recognizer.testingMarkModelsLoaded()

        try await recognizer.start()
        let runningAfterFirstStart = await recognizer.testingIsProcessing
        #expect(runningAfterFirstStart, "Processing loop should be live after start()")

        _ = try? await recognizer.finish()
        let runningAfterFinish = await recognizer.testingIsProcessing
        #expect(!runningAfterFinish, "Processing loop should be cancelled after finish()")

        try await recognizer.start()
        let runningAfterSecondStart = await recognizer.testingIsProcessing
        #expect(runningAfterSecondStart, "Processing loop must be re-armed after a second start()")
    }

    @Test("Reset cancels old processing loop and starts a new one")
    func resetReprovisionsLoop() async throws {
        let recognizer = Qwen3ASRStreamingRecognizer(size: .b0_6)
        await recognizer.testingMarkModelsLoaded()
        try await recognizer.start()
        let initialGeneration = await recognizer.testingProcessingTaskID
        try await recognizer.reset()
        let afterResetGeneration = await recognizer.testingProcessingTaskID
        #expect(afterResetGeneration > initialGeneration,
                "Reset should bump the processing-task generation counter (expected \(initialGeneration) → > \(initialGeneration), got \(afterResetGeneration))")
        let live = await recognizer.testingIsProcessing
        #expect(live, "Processing loop should be live after reset()")
    }
}
