import Testing
import Foundation
@testable import Domain
@testable import Core

@Suite("SubtitleFormatter")
struct SubtitleFormatterTests {

    @Test("Formats transcription segments into subtitle entries")
    func formatSegments() {
        let result = TranscriptionResult(
            text: "Hello world. How are you.",
            segments: [
                TranscriptionSegment(text: "Hello world.", start: 0.0, end: 2.5),
                TranscriptionSegment(text: "How are you.", start: 3.0, end: 5.0),
            ]
        )
        let formatter = SubtitleFormatter()
        let entries = formatter.format(result: result)
        #expect(entries.count == 2)
        #expect(entries[0].id == 1)
        #expect(entries[0].text == "Hello world.")
        #expect(abs(entries[0].timestamp.start - 0.0) < 0.001)
        #expect(abs(entries[0].timestamp.end - 2.5) < 0.001)
        #expect(entries[1].id == 2)
        #expect(entries[1].text == "How are you.")
    }

    @Test("Returns empty array for empty transcription")
    func formatEmptyTranscription() {
        let result = TranscriptionResult(text: "", segments: [])
        let formatter = SubtitleFormatter()
        let entries = formatter.format(result: result)
        #expect(entries.isEmpty)
    }

    @Test("Trims whitespace from segment text")
    func trimsWhitespace() {
        let result = TranscriptionResult(
            text: "Hello",
            segments: [
                TranscriptionSegment(text: "  Hello  ", start: 0.0, end: 1.0),
            ]
        )
        let formatter = SubtitleFormatter()
        let entries = formatter.format(result: result)
        #expect(entries[0].text == "Hello")
    }

    @Test("Skips segments with empty text after trimming")
    func skipsEmptySegments() {
        let result = TranscriptionResult(
            text: "Hello",
            segments: [
                TranscriptionSegment(text: "Hello", start: 0.0, end: 1.0),
                TranscriptionSegment(text: "   ", start: 1.0, end: 2.0),
                TranscriptionSegment(text: "World", start: 2.0, end: 3.0),
            ]
        )
        let formatter = SubtitleFormatter()
        let entries = formatter.format(result: result)
        #expect(entries.count == 2)
        #expect(entries[0].id == 1)
        #expect(entries[1].id == 2) // re-numbered
    }
}
