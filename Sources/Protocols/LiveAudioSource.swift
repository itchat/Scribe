@preconcurrency import AVFoundation
import Foundation

/// A live source of `AVAudioPCMBuffer`s for real-time captioning.
///
/// ISP: one start, one stop. Implementations decide where the audio comes from
/// (microphone, system audio via ScreenCaptureKit, a specific app's audio…)
/// without leaking that detail to the view model.
public protocol LiveAudioSource: Sendable {
    /// Begin streaming audio. The handler is invoked on whatever queue the
    /// implementation uses; consumers should hop to their own actor before
    /// touching shared state.
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws

    /// Stop streaming. Idempotent.
    func stop() async
}
