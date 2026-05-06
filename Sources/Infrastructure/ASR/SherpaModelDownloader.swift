@preconcurrency import Foundation
import os

/// Downloads & extracts the sherpa-onnx zh-en bilingual streaming Zipformer
/// model from the upstream GitHub release on first use, then caches it
/// under Application Support/.
///
/// SRP: only owns the "make the model files exist on disk" responsibility.
/// Path math + presence check live on `SherpaBilingualZhEnModelLocator`;
/// transcription lives on `SherpaOnnxStreamingRecognizer`.
/// DIP: callers see the locator (a value type), not this actor.
public actor SherpaModelDownloader {

    /// Public release URL for the int8 model bundle (~190 MB compressed).
    /// k2-fsa hosts pre-trained ASR models on a dedicated `asr-models`
    /// release tag rather than the per-version sherpa-onnx releases.
    public static let downloadURL = URL(
        string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2"
    )!

    private let logger = Logger(subsystem: "com.scribe", category: "asr.sherpa.downloader")
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns a fully-cached model locator, downloading + extracting on
    /// the first call. Idempotent: subsequent calls hit the cache.
    public func ensureAvailable() async throws -> SherpaBilingualZhEnModelLocator {
        let cacheRoot = try Self.cacheRoot()
        let locator = SherpaBilingualZhEnModelLocator(cacheRoot: cacheRoot)
        if locator.isComplete {
            return locator
        }

        try FileManager.default.createDirectory(
            at: cacheRoot,
            withIntermediateDirectories: true
        )

        logger.info(
            "Downloading sherpa-onnx zh-en model from \(Self.downloadURL.absoluteString, privacy: .public) ..."
        )

        // URLSession.download streams the body to a temp file — avoids
        // loading ~190 MB into memory.
        let (tarURL, response) = try await session.download(from: Self.downloadURL)
        defer { try? FileManager.default.removeItem(at: tarURL) }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SherpaModelDownloadError.badResponse(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }

        try extractTarBz2(from: tarURL, into: cacheRoot)

        guard locator.isComplete else {
            throw SherpaModelDownloadError.incompleteAfterExtract(modelDir: locator.modelDir)
        }

        logger.info("sherpa-onnx zh-en model ready at \(locator.modelDir.path, privacy: .public)")
        return locator
    }

    // MARK: - Private

    /// `~/Library/Application Support/Scribe/models/`. Consistent with the
    /// existing config file location under the same Scribe/ folder.
    private static func cacheRoot() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("Scribe", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// Shells out to `/usr/bin/tar` because Foundation has no built-in
    /// tar.bz2 extractor and pulling in libarchive for one tarball is
    /// disproportionate. The tarball top-level directory matches the
    /// upstream model name, so the post-extract layout already lines up
    /// with `SherpaBilingualZhEnModelLocator`.
    private func extractTarBz2(from archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw SherpaModelDownloadError.extractFailed(
                exitCode: process.terminationStatus,
                stderr: stderr
            )
        }
    }
}

public enum SherpaModelDownloadError: LocalizedError {
    case badResponse(status: Int)
    case extractFailed(exitCode: Int32, stderr: String)
    case incompleteAfterExtract(modelDir: URL)

    public var errorDescription: String? {
        switch self {
        case .badResponse(let status):
            return "sherpa-onnx model download returned HTTP \(status)"
        case .extractFailed(let code, let stderr):
            return "tar exited with code \(code) while unpacking sherpa-onnx model: \(stderr)"
        case .incompleteAfterExtract(let dir):
            return
                "Extracted sherpa-onnx model is missing required files at \(dir.path) — the tarball layout may have changed."
        }
    }
}
