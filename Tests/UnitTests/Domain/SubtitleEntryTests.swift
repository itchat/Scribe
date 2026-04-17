import Testing
import Foundation
@testable import Domain

@Suite("SubtitleEntry")
struct SubtitleEntryTests {

    @Test("Creates entry with required fields")
    func createBasicEntry() {
        let ts = SubtitleTimestamp(start: 1.0, end: 2.0)
        let entry = SubtitleEntry(id: 1, timestamp: ts, text: "Hello world")
        #expect(entry.id == 1)
        #expect(entry.text == "Hello world")
        #expect(entry.translatedText == nil)
    }

    @Test("Creates entry with translated text")
    func createWithTranslation() {
        let ts = SubtitleTimestamp(start: 1.0, end: 2.0)
        let entry = SubtitleEntry(id: 1, timestamp: ts, text: "Hello", translatedText: "你好")
        #expect(entry.translatedText == "你好")
    }

    @Test("bilingual text combines original and translated")
    func bilingualText() {
        let ts = SubtitleTimestamp(start: 1.0, end: 2.0)
        let entry = SubtitleEntry(id: 1, timestamp: ts, text: "Hello", translatedText: "你好")
        #expect(entry.bilingualText == "Hello\n你好")
    }

    @Test("bilingual text returns original when no translation")
    func bilingualTextNoTranslation() {
        let ts = SubtitleTimestamp(start: 1.0, end: 2.0)
        let entry = SubtitleEntry(id: 1, timestamp: ts, text: "Hello")
        #expect(entry.bilingualText == "Hello")
    }

    @Test("Entries with same values are equal")
    func equality() {
        let ts = SubtitleTimestamp(start: 1.0, end: 2.0)
        let a = SubtitleEntry(id: 1, timestamp: ts, text: "Hello")
        let b = SubtitleEntry(id: 1, timestamp: ts, text: "Hello")
        #expect(a == b)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let ts = SubtitleTimestamp(start: 1.5, end: 3.0)
        let original = SubtitleEntry(id: 42, timestamp: ts, text: "Test", translatedText: "测试")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SubtitleEntry.self, from: data)
        #expect(decoded == original)
    }
}
