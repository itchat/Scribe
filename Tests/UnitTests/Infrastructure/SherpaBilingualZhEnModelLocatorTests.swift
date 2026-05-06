import Testing
import Foundation
@testable import Infrastructure

/// Pins the on-disk layout the sherpa-onnx zh-en bilingual streaming
/// recognizer expects: a directory containing the four int8 ONNX files
/// (encoder/decoder/joiner) plus tokens.txt. The locator is purely
/// path construction + a "are all files present?" predicate, so it's
/// fully unit-testable with a temp directory.
@Suite("SherpaBilingualZhEnModelLocator")
struct SherpaBilingualZhEnModelLocatorTests {

    // MARK: - Helpers

    private func makeTempCacheRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scribe-sherpa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: url)
    }

    // MARK: - Path construction

    @Test("Encoder/decoder/joiner/tokens paths sit under the model subdirectory")
    func pathsAreUnderModelSubdir() throws {
        let root = try makeTempCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = SherpaBilingualZhEnModelLocator(cacheRoot: root)

        // Compare directory-portion → modelDir using the locator's own
        // `modelDir` to avoid trailing-slash URL inequality.
        #expect(locator.encoderPath.deletingLastPathComponent() == locator.modelDir)
        #expect(locator.decoderPath.deletingLastPathComponent() == locator.modelDir)
        #expect(locator.joinerPath.deletingLastPathComponent() == locator.modelDir)
        #expect(locator.tokensPath.deletingLastPathComponent() == locator.modelDir)
        #expect(locator.modelDir.lastPathComponent == "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20")
    }

    /// fp32 ONNX files match what the upstream sherpa-onnx swift example
    /// (`swift-api-examples/decode-file.swift`) loads for the bilingual
    /// model. We tried int8 first but loading crashed inside the C runtime
    /// (`SherpaOnnxCreateOnlineRecognizer` returned nil and the wrapper
    /// then dereferenced it building the stream). Stick to the
    /// upstream-validated weights.
    @Test("Uses fp32 ONNX filenames matching the upstream decode-file.swift template")
    func usesFp32FileNames() throws {
        let root = try makeTempCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = SherpaBilingualZhEnModelLocator(cacheRoot: root)

        #expect(locator.encoderPath.lastPathComponent == "encoder-epoch-99-avg-1.onnx")
        #expect(locator.decoderPath.lastPathComponent == "decoder-epoch-99-avg-1.onnx")
        #expect(locator.joinerPath.lastPathComponent == "joiner-epoch-99-avg-1.onnx")
        #expect(locator.tokensPath.lastPathComponent == "tokens.txt")
    }

    // MARK: - isComplete predicate

    @Test("isComplete is false on an empty cache directory")
    func incompleteWhenEmpty() throws {
        let root = try makeTempCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = SherpaBilingualZhEnModelLocator(cacheRoot: root)
        #expect(!locator.isComplete)
    }

    @Test("isComplete is false when only a subset of files is present")
    func incompleteWhenSomeFilesMissing() throws {
        let root = try makeTempCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = SherpaBilingualZhEnModelLocator(cacheRoot: root)
        // Touch encoder + tokens but leave decoder + joiner missing.
        try touch(locator.encoderPath)
        try touch(locator.tokensPath)

        #expect(!locator.isComplete)
    }

    @Test("isComplete is true once all four required files exist")
    func completeWhenAllFilesPresent() throws {
        let root = try makeTempCacheRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let locator = SherpaBilingualZhEnModelLocator(cacheRoot: root)
        try touch(locator.encoderPath)
        try touch(locator.decoderPath)
        try touch(locator.joinerPath)
        try touch(locator.tokensPath)

        #expect(locator.isComplete)
    }
}
