import Testing
import Foundation
@testable import Domain
@testable import Core

@Suite("ResponseRecovery")
struct ResponseRecoveryTests {

    // MARK: - Primary separator

    @Test("Splits correctly with matching primary separator")
    func primarySeparatorMatch() {
        let combined = "Hello%%World%%Foo"
        let result = ResponseRecovery.recover(
            combined: combined,
            expectedCount: 3,
            separator: "%%"
        )
        #expect(result.count == 3)
        #expect(result[0] == "Hello")
        #expect(result[1] == "World")
        #expect(result[2] == "Foo")
    }

    @Test("Returns single-element array for single entry")
    func singleEntry() {
        let result = ResponseRecovery.recover(
            combined: "Hello world",
            expectedCount: 1,
            separator: "%%"
        )
        #expect(result.count == 1)
        #expect(result[0] == "Hello world")
    }

    // MARK: - Alternate separators

    @Test("Falls back to alternate separator when primary fails")
    func alternateSeparator() {
        // Primary separator %% gives wrong count, but 🔸🔸🔸 works
        let combined = "Hello\n\u{1F538}\u{1F538}\u{1F538}\nWorld"
        let result = ResponseRecovery.recover(
            combined: combined,
            expectedCount: 2,
            separator: "%%"
        )
        #expect(result.count == 2)
    }

    // MARK: - Line-based recovery

    @Test("Falls back to line splitting when no separator matches")
    func lineBasedRecovery() {
        let combined = "Line1\nLine2\nLine3\nLine4"
        let result = ResponseRecovery.recover(
            combined: combined,
            expectedCount: 2,
            separator: "%%"
        )
        // 4 lines / 2 entries = 2 lines per entry
        #expect(result.count == 2)
    }

    // MARK: - Count mismatch

    @Test("Returns raw split when nothing matches expected count")
    func noRecoveryPossible() {
        let combined = "only one piece"
        let result = ResponseRecovery.recover(
            combined: combined,
            expectedCount: 5,
            separator: "%%"
        )
        // Can't recover to 5, returns whatever the primary split gives
        #expect(result.count == 1)
    }

    // MARK: - Pad / Truncate

    @Test("Pads missing translations with original text")
    func padMissing() {
        let entries = [
            SubtitleEntry(id: 1, timestamp: SubtitleTimestamp(start: 0, end: 1), text: "A"),
            SubtitleEntry(id: 2, timestamp: SubtitleTimestamp(start: 1, end: 2), text: "B"),
            SubtitleEntry(id: 3, timestamp: SubtitleTimestamp(start: 2, end: 3), text: "C"),
        ]
        let translations = ["翻译A"]
        let result = ResponseRecovery.padOrTruncate(translations: translations, entries: entries)
        #expect(result.count == 3)
        #expect(result[0] == "翻译A")
        #expect(result[1] == "B")  // padded with original
        #expect(result[2] == "C")  // padded with original
    }

    @Test("Truncates excess translations")
    func truncateExcess() {
        let entries = [
            SubtitleEntry(id: 1, timestamp: SubtitleTimestamp(start: 0, end: 1), text: "A"),
        ]
        let translations = ["翻译A", "多余的", "更多余的"]
        let result = ResponseRecovery.padOrTruncate(translations: translations, entries: entries)
        #expect(result.count == 1)
        #expect(result[0] == "翻译A")
    }

    @Test("Returns as-is when counts match")
    func exactMatch() {
        let entries = [
            SubtitleEntry(id: 1, timestamp: SubtitleTimestamp(start: 0, end: 1), text: "A"),
            SubtitleEntry(id: 2, timestamp: SubtitleTimestamp(start: 1, end: 2), text: "B"),
        ]
        let translations = ["翻译A", "翻译B"]
        let result = ResponseRecovery.padOrTruncate(translations: translations, entries: entries)
        #expect(result.count == 2)
        #expect(result[0] == "翻译A")
        #expect(result[1] == "翻译B")
    }
}
