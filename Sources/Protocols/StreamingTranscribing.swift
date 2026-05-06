@preconcurrency import AVFoundation
import Foundation
import Domain

/// Streaming ASR contract used by the live-captions feature.
///
/// LSP: every conformer returns the same `LiveCaptionUpdate` shape via the
/// `partials` AsyncStream. ISP: protocol stays narrow; auxiliary concerns
/// (model download progress, language hints) live on richer protocols if a
/// future engine needs them.
public protocol StreamingTranscribing: Sendable {
    /// Stream of partial transcript snapshots. Cumulative — each value is the
    /// best-known full transcript so far, not a delta.
    var partials: AsyncStream<LiveCaptionUpdate> { get async }

    /// Load models if needed. Idempotent.
    func start() async throws

    /// Append a chunk of audio. The implementation buffers and runs the engine
    /// at its own cadence; consumers do not have to align to chunk boundaries.
    func appendAudio(_ buffer: AVAudioPCMBuffer) async throws

    /// Flush remaining audio and return the final transcript.
    func finish() async throws -> String

    /// Reset session state without unloading models.
    func reset() async throws
}
