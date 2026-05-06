import Testing
import Foundation
@testable import Domain

/// Locks the canonical set of translation modes and their string raw values.
/// `TranslationMode` replaces the bool `skipTranslation` + the `TranslationEngine`
/// picker into a single 3-way toggle (Off / OpenAI / Google).
@Suite("TranslationMode")
struct TranslationModeTests {

    @Test("Cases are exactly off / openAI / google")
    func canonicalCases() {
        #expect(TranslationMode.allCases == [.off, .openAI, .google])
    }

    @Test("Codable round-trip preserves identity")
    func codableRoundTrip() throws {
        for mode in TranslationMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(TranslationMode.self, from: data)
            #expect(decoded == mode)
        }
    }

    @Test("Display name is non-empty for each case")
    func displayNamesAreNonEmpty() {
        for mode in TranslationMode.allCases {
            #expect(!mode.displayName.isEmpty)
        }
    }

    @Test("toEngine returns nil only for .off")
    func toEngineMapping() {
        #expect(TranslationMode.off.toEngine() == nil)
        #expect(TranslationMode.openAI.toEngine() == .openAI)
        #expect(TranslationMode.google.toEngine() == .google)
    }
}
