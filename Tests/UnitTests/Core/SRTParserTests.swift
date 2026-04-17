import Testing
import Foundation
@testable import Domain
@testable import Core

@Suite("SRTParser")
struct SRTParserTests {

    // MARK: - Standard parsing

    @Test("Parses standard SRT content")
    func parseStandard() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Hello world

        2
        00:00:04,000 --> 00:00:06,000
        How are you

        """
        let entries = try SRTParser.parse(srt)
        #expect(entries.count == 2)
        #expect(entries[0].id == 1)
        #expect(entries[0].text == "Hello world")
        #expect(entries[1].id == 2)
        #expect(entries[1].text == "How are you")
    }

    @Test("Parses multi-line subtitle text")
    func parseMultiLineText() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Line one
        Line two

        """
        let entries = try SRTParser.parse(srt)
        #expect(entries.count == 1)
        #expect(entries[0].text == "Line one\nLine two")
    }

    @Test("Parses SRT without trailing newline")
    func parseWithoutTrailingNewline() throws {
        let srt = "1\n00:00:01,000 --> 00:00:03,000\nHello world"
        let entries = try SRTParser.parse(srt)
        #expect(entries.count == 1)
        #expect(entries[0].text == "Hello world")
    }

    @Test("Parses SRT with extra blank lines between entries")
    func parseExtraBlankLines() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        First


        2
        00:00:04,000 --> 00:00:06,000
        Second

        """
        let entries = try SRTParser.parse(srt)
        #expect(entries.count == 2)
    }

    @Test("Returns empty array for empty string")
    func parseEmpty() throws {
        let entries = try SRTParser.parse("")
        #expect(entries.isEmpty)
    }

    @Test("Returns empty array for whitespace-only string")
    func parseWhitespaceOnly() throws {
        let entries = try SRTParser.parse("   \n\n   \n")
        #expect(entries.isEmpty)
    }

    @Test("Preserves timestamp in parsed entries")
    func preservesTimestamp() throws {
        let srt = """
        1
        00:01:23,456 --> 00:01:25,789
        Test

        """
        let entries = try SRTParser.parse(srt)
        #expect(entries.count == 1)
        #expect(abs(entries[0].timestamp.start - 83.456) < 0.001)
        #expect(abs(entries[0].timestamp.end - 85.789) < 0.001)
    }

    @Test("Parses bilingual subtitle (original + translated)")
    func parseBilingual() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Hello world
        你好世界

        """
        let entries = try SRTParser.parse(srt)
        #expect(entries.count == 1)
        #expect(entries[0].text == "Hello world\n你好世界")
    }
}

@Suite("SRTWriter")
struct SRTWriterTests {

    @Test("Writes standard SRT format")
    func writeStandard() {
        let entries = [
            SubtitleEntry(
                id: 1,
                timestamp: SubtitleTimestamp(start: 1.0, end: 3.0),
                text: "Hello world"
            ),
            SubtitleEntry(
                id: 2,
                timestamp: SubtitleTimestamp(start: 4.0, end: 6.0),
                text: "How are you"
            ),
        ]
        let output = SRTWriter.write(entries)
        // SRT format: each entry ends with blank line (including last)
        #expect(output.contains("1\n00:00:01,000 --> 00:00:03,000\nHello world\n"))
        #expect(output.contains("2\n00:00:04,000 --> 00:00:06,000\nHow are you\n"))
        #expect(output.hasSuffix("\n"))
    }

    @Test("Writes bilingual entries using bilingualText")
    func writeBilingual() {
        let entries = [
            SubtitleEntry(
                id: 1,
                timestamp: SubtitleTimestamp(start: 1.0, end: 3.0),
                text: "Hello",
                translatedText: "你好"
            ),
        ]
        let output = SRTWriter.write(entries, bilingual: true)
        #expect(output.contains("Hello\n你好"))
    }

    @Test("Writes empty array as empty string")
    func writeEmpty() {
        let output = SRTWriter.write([])
        #expect(output.isEmpty)
    }

    // MARK: - Round-trip

    @Test("Round-trip: write then parse preserves data")
    func roundTrip() throws {
        let original = [
            SubtitleEntry(
                id: 1,
                timestamp: SubtitleTimestamp(start: 1.0, end: 3.0),
                text: "Hello world"
            ),
            SubtitleEntry(
                id: 2,
                timestamp: SubtitleTimestamp(start: 4.5, end: 6.5),
                text: "How are you"
            ),
        ]
        let srt = SRTWriter.write(original)
        let parsed = try SRTParser.parse(srt)
        #expect(parsed.count == original.count)
        for i in 0..<original.count {
            #expect(parsed[i].id == original[i].id)
            #expect(parsed[i].text == original[i].text)
            #expect(abs(parsed[i].timestamp.start - original[i].timestamp.start) < 0.001)
        }
    }
}
