@preconcurrency import Foundation
import CryptoKit
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

    /// Expected SHA-256 of the archive, lowercase hex, or nil to skip.
    private let expectedSHA256: String?

    public init(
        downloadURL: URL,
        modelName: String,
        expectedSHA256: String? = nil,
        session: URLSession = .shared
    ) {
        self.downloadURL = downloadURL
        self.modelName = modelName
        self.expectedSHA256 = expectedSHA256
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

        if let expectedSHA256 {
            try Self.verifyDigest(of: tarURL, expected: expectedSHA256)
        }

        // Extract into a staging directory, validate the layout, and only
        // then move it into place. Extracting straight into the cache root
        // trusted the archive's own entry names: BSD tar's defaults reject
        // `..` and strip a leading `/`, but nothing stopped an archive from
        // creating a symlink that points outside the cache and then writing
        // *through* it.
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try Self.extractTarBz2(from: tarURL, into: staging)
        try Self.rejectSymlinks(in: staging)

        let extracted = staging.appendingPathComponent(modelDirName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw SherpaTarballDownloadError.incompleteAfterExtract(modelDir: extracted)
        }

        if FileManager.default.fileExists(atPath: modelDir.path) {
            try FileManager.default.removeItem(at: modelDir)
        }
        try FileManager.default.moveItem(at: extracted, to: modelDir)

        guard isComplete(modelDir) else {
            throw SherpaTarballDownloadError.incompleteAfterExtract(modelDir: modelDir)
        }

        // Model name is a fixed identifier; the path embeds the home
        // directory and therefore the account name.
        logger.info("\(self.modelName, privacy: .public) ready at \(modelDir.path, privacy: .private)")
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
    /// Verify a downloaded archive against a known digest.
    ///
    /// GitHub release assets are mutable by the repo owner, so HTTPS proves
    /// only who served the bytes, not which bytes they were. These archives
    /// are unpacked and loaded as model weights, so they get checked when a
    /// digest is known.
    static func verifyDigest(of file: URL, expected: String) throws {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw SherpaTarballDownloadError.digestMismatch(expected: expected, actual: actual)
        }
    }

    /// Reject any symlink anywhere in the extracted tree.
    ///
    /// A tarball containing `evil -> /Users/you/Library` followed by
    /// `evil/LaunchAgents/x.plist` writes outside the cache root without ever
    /// using a `..` component, so tar's own traversal defences don't help.
    /// These model archives legitimately contain only regular files and
    /// directories, so refusing symlinks outright costs nothing.
    static func rejectSymlinks(in directory: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return }

        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                throw SherpaTarballDownloadError.unsafeArchiveEntry(path: url.lastPathComponent)
            }
        }
    }

    static func extractTarBz2(from archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // `--no-same-owner` so extraction never attempts to honour uid/gid
        // recorded in the archive.
        process.arguments = ["-xjf", archive.path, "-C", directory.path, "--no-same-owner"]
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
    case digestMismatch(expected: String, actual: String)
    case unsafeArchiveEntry(path: String)

    public var description: String {
        switch self {
        case .badResponse(let status):
            return "HTTP \(status) downloading sherpa-onnx tarball"
        case .tarFailed(let stderr):
            return "tar -xjf failed: \(stderr)"
        case .incompleteAfterExtract(let modelDir):
            return "model directory missing required files after extract: \(modelDir.path)"
        case .digestMismatch(let expected, let actual):
            return "model archive checksum mismatch — expected \(expected), got \(actual)"
        case .unsafeArchiveEntry(let path):
            return "model archive contains a symbolic link (\(path)); refusing to install it"
        }
    }
}
