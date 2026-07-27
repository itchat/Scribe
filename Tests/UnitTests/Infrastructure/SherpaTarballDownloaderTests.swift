import Testing
import Foundation
import CryptoKit
@testable import Infrastructure

/// Extraction and integrity checks for downloaded model archives.
///
/// Previously untested end to end: the download/extract path had no coverage
/// of its error branches, and nothing verified that a hostile archive could
/// not write outside the cache directory.
@Suite("SherpaTarballDownloader")
struct SherpaTarballDownloaderTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-tarball-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func run(_ args: [String], in dir: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = args
        process.currentDirectoryURL = dir
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    // MARK: - Digest verification

    @Test("Accepts an archive matching its expected digest")
    func digestMatches() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("payload.bin")
        let bytes = Data("sherpa model bytes".utf8)
        try bytes.write(to: file)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        // Must not throw.
        try SherpaTarballDownloader.verifyDigest(of: file, expected: digest)
        // Case-insensitive, since published digests vary in case.
        try SherpaTarballDownloader.verifyDigest(of: file, expected: digest.uppercased())
    }

    @Test("Rejects an archive whose bytes changed")
    func digestMismatchRejected() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("payload.bin")
        try Data("tampered".utf8).write(to: file)
        let wrongDigest = String(repeating: "ab", count: 32)

        #expect(throws: SherpaTarballDownloadError.self) {
            try SherpaTarballDownloader.verifyDigest(of: file, expected: wrongDigest)
        }
    }

    // MARK: - Archive safety

    /// The attack the staging step exists to stop: a symlink pointing outside
    /// the cache root, which a later archive entry can then write through.
    /// No `..` component is involved, so tar's own traversal defences do not
    /// apply.
    @Test("Rejects an extracted tree containing a symbolic link")
    func symlinkEscapeRejected() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let payload = work.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: payload.appendingPathComponent("escape").path,
            withDestinationPath: "/tmp"
        )

        #expect(throws: SherpaTarballDownloadError.self) {
            try SherpaTarballDownloader.rejectSymlinks(in: work)
        }
    }

    @Test("Accepts a tree of ordinary files and directories")
    func ordinaryTreeAccepted() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let nested = work.appendingPathComponent("model/sub", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: nested.appendingPathComponent("encoder.onnx"))

        // Must not throw.
        try SherpaTarballDownloader.rejectSymlinks(in: work)
    }

    // MARK: - Extraction

    @Test("Extracts a well-formed archive")
    func extractsArchive() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let source = work.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("tokens".utf8).write(to: source.appendingPathComponent("tokens.txt"))

        let archive = work.appendingPathComponent("model.tar.bz2")
        #expect(try run(["-cjf", archive.path, "model"], in: work) == 0)

        let destination = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try SherpaTarballDownloader.extractTarBz2(from: archive, into: destination)

        let extracted = destination.appendingPathComponent("model/tokens.txt")
        #expect(FileManager.default.fileExists(atPath: extracted.path))
    }

    /// A symlinked archive must be caught after extraction, before anything
    /// is moved into the model cache.
    @Test("Catches a symlink that survives real extraction")
    func extractedSymlinkCaught() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let source = work.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("escape").path,
            withDestinationPath: "/tmp"
        )

        let archive = work.appendingPathComponent("evil.tar.bz2")
        #expect(try run(["-cjf", archive.path, "model"], in: work) == 0)

        let destination = work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try SherpaTarballDownloader.extractTarBz2(from: archive, into: destination)

        #expect(throws: SherpaTarballDownloadError.self) {
            try SherpaTarballDownloader.rejectSymlinks(in: destination)
        }
    }

    @Test("Reports a corrupt archive rather than succeeding silently")
    func corruptArchiveThrows() throws {
        let work = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }

        let archive = work.appendingPathComponent("broken.tar.bz2")
        try Data("this is not a bzip2 stream".utf8).write(to: archive)

        #expect(throws: SherpaTarballDownloadError.self) {
            try SherpaTarballDownloader.extractTarBz2(from: archive, into: work)
        }
    }
}
