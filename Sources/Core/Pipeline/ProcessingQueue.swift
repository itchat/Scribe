import Foundation
import Domain
import Protocols

/// Manages sequential processing of multiple video files.
///
/// SRP: Only responsible for queue management — delegates actual processing to `VideoPipeline`.
public final class ProcessingQueue: @unchecked Sendable {

    /// Factory closure that creates a pipeline for a given video URL.
    public typealias PipelineFactory = @Sendable (URL, (any Protocols.ProgressReporting)?) -> VideoPipeline

    private let createPipeline: PipelineFactory

    public init(pipelineFactory: @escaping PipelineFactory) {
        self.createPipeline = pipelineFactory
    }

    /// Process all video URLs sequentially, returning results in order.
    /// Continues processing remaining videos even if one fails.
    public func processAll(
        _ videoURLs: [URL],
        progress: (any Protocols.ProgressReporting)? = nil
    ) async -> [ProcessingResult] {
        var results: [ProcessingResult] = []

        for (index, videoURL) in videoURLs.enumerated() {
            progress?.reportStatus("Processing \(index + 1)/\(videoURLs.count): \(videoURL.lastPathComponent)")

            let pipeline = createPipeline(videoURL, progress)
            let result = await pipeline.process()
            results.append(result)
        }

        return results
    }
}
