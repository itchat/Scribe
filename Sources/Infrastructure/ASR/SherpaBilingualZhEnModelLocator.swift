import Foundation

/// Knows where the sherpa-onnx zh-en bilingual streaming Zipformer model
/// lives on disk and can answer "is the full bundle already cached?".
///
/// SRP: only path math + a presence check. The download / extraction
/// flow lives in `SherpaModelDownloader`; transcription lives in
/// `SherpaOnnxStreamingRecognizer`. Splitting the cache layout into a
/// pure value type lets the unit tests stay fast and offline.
public struct SherpaBilingualZhEnModelLocator: Sendable {

    /// Directory name inside the cache root — matches the upstream tarball's
    /// top-level directory so unpacking the archive directly yields the
    /// expected layout without further moves.
    public static let modelDirName = "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"

    public let cacheRoot: URL
    public let modelDir: URL
    public let encoderPath: URL
    public let decoderPath: URL
    public let joinerPath: URL
    public let tokensPath: URL

    public init(cacheRoot: URL) {
        self.cacheRoot = cacheRoot
        let dir = cacheRoot.appendingPathComponent(Self.modelDirName, isDirectory: true)
        self.modelDir = dir
        // fp32 ONNX weights — the upstream sherpa-onnx swift example
        // (`decode-file.swift`) loads these exact filenames. The tarball
        // also ships int8 variants (~190 MB vs 342 MB), but loading them
        // crashed `SherpaOnnxCreateOnlineRecognizer` in our integration
        // (returned nil → the wrapper dereferenced it building the
        // stream → segfault). fp32 is the upstream-validated path.
        self.encoderPath = dir.appendingPathComponent("encoder-epoch-99-avg-1.onnx")
        self.decoderPath = dir.appendingPathComponent("decoder-epoch-99-avg-1.onnx")
        self.joinerPath  = dir.appendingPathComponent("joiner-epoch-99-avg-1.onnx")
        self.tokensPath  = dir.appendingPathComponent("tokens.txt")
    }

    /// All four required files must exist for the recognizer to load. A
    /// half-extracted archive (encoder present, joiner missing) reports
    /// `false` and triggers a re-download.
    public var isComplete: Bool {
        let fm = FileManager.default
        return [encoderPath, decoderPath, joinerPath, tokensPath].allSatisfy {
            fm.fileExists(atPath: $0.path)
        }
    }
}
