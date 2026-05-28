import Testing
import Foundation
@testable import Domain

/// Locks the canonical set of supported live-caption engines.
///
/// This suite intentionally enumerates every case — adding or removing an
/// engine is a deliberate API change and should require updating these
/// assertions, not silently editing the enum. Acts as a regression guard
/// against accidental re-introduction of removed engines (e.g. the Qwen3
/// path that was deleted because we don't ship cloud-API or
/// macOS-15-gated recognizers).
@Suite("LiveCaptionEngine")
struct LiveCaptionEngineTests {

    @Test("Supported engines are exactly Nemotron, Zipformer zh-XLarge, Paraformer trilingual, Qwen3-ASR 0.6B/1.7B")
    func supportedEngines() {
        #expect(LiveCaptionEngine.allCases == [
            .nemotron, .zipformerZhXLarge, .paraformerTrilingual,
            .qwen3ASRSmall, .qwen3ASRLarge,
        ])
    }

    @Test("Every case has a non-empty display name")
    func displayNamesAreNonEmpty() {
        for engine in LiveCaptionEngine.allCases {
            #expect(!engine.displayName.isEmpty, "displayName for \(engine) is empty")
        }
    }

    @Test("Every case has a non-empty download size label")
    func downloadSizeLabelsAreNonEmpty() {
        for engine in LiveCaptionEngine.allCases {
            #expect(!engine.downloadSizeLabel.isEmpty, "downloadSizeLabel for \(engine) is empty")
        }
    }

    @Test("Codable round-trip preserves identity for every case")
    func codableRoundTrip() throws {
        for engine in LiveCaptionEngine.allCases {
            let data = try JSONEncoder().encode(engine)
            let decoded = try JSONDecoder().decode(LiveCaptionEngine.self, from: data)
            #expect(decoded == engine)
        }
    }

}
