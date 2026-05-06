@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import Foundation
import os
import Domain
import Protocols

/// Captures macOS system audio (everything the user hears) via ScreenCaptureKit
/// and forwards it to a closure as `AVAudioPCMBuffer`s.
///
/// SRP: only audio capture. Knows nothing about ASR or UI.
/// DIP: callers depend on `LiveAudioSource`, never this concrete actor.
///
/// Permission model: requires the user to grant Screen Recording in
/// System Settings → Privacy & Security. `start()` will fail with a clear
/// error if access has not been granted; `SystemAudioPermission` is the
/// helper that prompts and surfaces a path to the settings pane.
public actor SystemAudioCapture: LiveAudioSource {

    private let logger = Logger(subsystem: "com.scribe", category: "audio.system")
    private var stream: SCStream?
    private var output: AudioStreamOutput?

    public init() {}

    public func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        // Already running? Treat repeat-start as a no-op so the UI's start
        // button can be tapped twice without exploding.
        if stream != nil { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw ScribeError.audioExtractionFailed(
                underlying: NSError(domain: "SystemAudioCapture", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No displays available for capture"
                ])
            )
        }

        // We only want audio; create a content filter that excludes Scribe's
        // own windows (so we never capture our own output if we ever play it
        // back through the speakers).
        let ourWindows = content.windows.filter { $0.owningApplication?.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ourWindows)

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        // Keep video config minimal — ScreenCaptureKit currently requires a
        // video stream even when only audio is needed; configuring 2×2 at 1 fps
        // keeps the CPU/GPU cost negligible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = AudioStreamOutput(onBuffer: onBuffer)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "scribe.system-audio"))
        // Discard the video frames we have to ask for; we just don't read them.
        try stream.addStreamOutput(VideoSinkOutput(), type: .screen, sampleHandlerQueue: DispatchQueue(label: "scribe.system-video-sink"))

        try await stream.startCapture()
        self.stream = stream
        self.output = output
        logger.info("System audio capture started (display=\(display.displayID), excluding \(ourWindows.count) own windows)")
    }

    public func stop() async {
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            logger.warning("stopCapture failed: \(error.localizedDescription, privacy: .public)")
        }
        self.stream = nil
        self.output = nil
        logger.info("System audio capture stopped")
    }
}

/// SCStream output that converts `CMSampleBuffer` (PCM) → `AVAudioPCMBuffer` and
/// invokes the consumer's closure. Class because `SCStreamOutput` is a class
/// protocol; `@unchecked Sendable` because it just forwards immutable data.
private final class AudioStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void

    init(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.onBuffer = onBuffer
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let format = sampleBuffer.formatDescription,
              let asbd = format.audioStreamBasicDescription
        else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return }

        var asbdMutable = asbd
        guard let avFormat = AVAudioFormat(streamDescription: &asbdMutable) else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // Copy samples out of the CMSampleBuffer into the PCM buffer's audioBufferList.
        let listPtr = pcmBuffer.mutableAudioBufferList
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: listPtr
        )
        guard status == noErr else { return }

        onBuffer(pcmBuffer)
    }
}

/// Discards the (mandatory but unused) video frames from SCStream.
private final class VideoSinkOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // intentionally empty — we only care about audio.
    }
}
