import Testing
import Foundation
@testable import Domain

/// Locks the canonical set of supported offline-batch ASR engines.
///
/// Mirror of `LiveCaptionEngineTests` — adding or removing an engine is a
/// deliberate API change and must require updating these assertions, not
/// silently editing the enum.
@Suite("OfflineASREngine")
struct OfflineASREngineTests {

    @Test("Supported engines are exactly Parakeet v2, Qwen3 0.6B, Qwen3 1.7B")
    func supportedEngines() {
        #expect(OfflineASREngine.allCases == [.parakeetV2, .qwen3_0_6B, .qwen3_1_7B])
    }

    @Test("Every case has a non-empty display name")
    func displayNamesAreNonEmpty() {
        for engine in OfflineASREngine.allCases {
            #expect(!engine.displayName.isEmpty, "displayName for \(engine) is empty")
        }
    }

    @Test("Every case has a non-empty download size label")
    func downloadSizeLabelsAreNonEmpty() {
        for engine in OfflineASREngine.allCases {
            #expect(!engine.downloadSizeLabel.isEmpty, "downloadSizeLabel for \(engine) is empty")
        }
    }

    @Test("Codable round-trip preserves identity for every case")
    func codableRoundTrip() throws {
        for engine in OfflineASREngine.allCases {
            let data = try JSONEncoder().encode(engine)
            let decoded = try JSONDecoder().decode(OfflineASREngine.self, from: data)
            #expect(decoded == engine)
        }
    }
}
