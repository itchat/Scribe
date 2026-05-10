@preconcurrency import Foundation
import os

/// Generic downloader for sherpa-onnx tarballs hosted on the
/// `k2-fsa/sherpa-onnx` releases. Each model's locator decides what it
/// expects on disk; this actor owns the "make a tarball's contents
/// exist on disk under the cache root" responsibility.
///
/// SRP: only download + tar extraction. Path math + presence checks
/// live on per-model `…Locator` value types; transcription lives on
/// per-model `…Recognizer` actors. Splitting these lets the unit
/// tests stay fast and offline.
public actor SherpaTarballDownloader {

    private let logger = Logger(subsystem: "com.scribe", category: "asr.sherpa.downloader")
    private let session: URLSession
    private let downloadURL: URL
    private let modelName: String

    public init(
        downloadURL: URL,
        modelName: String,
        session: URLSession = .shared
    ) {
        self.downloadURL = downloadURL
        self.modelName = modelName
        self.session = session
    }

    /// Returns the model directory (under `Application Support/Scribe/
    /// models/`), downloading + extracting the tarball if it's not
    /// already on disk. The closure decides whether the cached files
    /// look complete enough to skip the download.
    public func ensureExtracted(
        cacheRoot: URL? = nil,
        modelDirName: String,
        isComplete: (URL) -> Bool
    ) async throws -> URL {
        let root = try cacheRoot ?? Self.defaultCacheRoot()
        let modelDir = root.appendingPathComponent(modelDirName, isDirectory: true)

        if isComplete(modelDir) {
            return modelDir
        }

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )

        logger.info("Downloading \(self.modelName, privacy: .public) from \(self.downloadURL.absoluteString, privacy: .public) ...")

        let (tarURL, response) = try await session.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: tarURL) }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SherpaTarballDownloadError.badResponse(
                status: (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }

        try Self.extractTarBz2(from: tarURL, into: root)

        guard isComplete(modelDir) else {
            throw SherpaTarballDownloadError.incompleteAfterExtract(modelDir: modelDir)
        }

        logger.info("\(self.modelName, privacy: .public) ready at \(modelDir.path, privacy: .public)")
        return modelDir
    }

    // MARK: - Helpers

    /// `~/Library/Application Support/Scribe/models/` — same root the
    /// existing `SherpaModelDownloader` uses, so all sherpa-onnx models
    /// (old and new) land in one place.
    public static func defaultCacheRoot() throws -> URL {
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
    /// disproportionate. The k2-fsa tarballs all have a top-level dir
    /// matching the tarball's basename, so post-extract layout matches
    /// the locator's expectations directly.
    static func extractTarBz2(from archive: URL, into directory: URL) throws {
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
            throw SherpaTarballDownloadError.tarFailed(stderr: stderr)
        }
    }
}

public enum SherpaTarballDownloadError: Error, CustomStringConvertible {
    case badResponse(status: Int)
    case tarFailed(stderr: String)
    case incompleteAfterExtract(modelDir: URL)

    public var description: String {
        switch self {
        case .badResponse(let status):
            return "HTTP \(status) downloading sherpa-onnx tarball"
        case .tarFailed(let stderr):
            return "tar -xjf failed: \(stderr)"
        case .incompleteAfterExtract(let modelDir):
            return "model directory missing required files after extract: \(modelDir.path)"
        }
    }
}
