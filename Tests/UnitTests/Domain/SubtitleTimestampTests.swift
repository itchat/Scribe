import Testing
@testable import Domain

@Suite("SubtitleTimestamp")
struct SubtitleTimestampTests {

    // MARK: - Parsing from SRT string

    @Test("Parses standard SRT timestamp")
    func parseStandardTimestamp() throws {
        let ts = try SubtitleTimestamp(srtString: "00:01:23,456 --> 00:01:25,789")
        #expect(abs(ts.start - 83.456) < 0.001)
        #expect(abs(ts.end - 85.789) < 0.001)
    }

    @Test("Parses zero timestamp")
    func parseZeroTimestamp() throws {
        let ts = try SubtitleTimestamp(srtString: "00:00:00,000 --> 00:00:00,000")
        #expect(ts.start == 0.0)
        #expect(ts.end == 0.0)
    }

    @Test("Parses hour-level timestamp")
    func parseHourTimestamp() throws {
        let ts = try SubtitleTimestamp(srtString: "02:30:45,100 --> 02:30:50,900")
        #expect(abs(ts.start - 9045.1) < 0.001)
        #expect(abs(ts.end - 9050.9) < 0.001)
    }

    @Test("Parses timestamp with extra whitespace")
    func parseTimestampWithWhitespace() throws {
        let ts = try SubtitleTimestamp(srtString: "  00:00:01,000  -->  00:00:02,000  ")
        #expect(abs(ts.start - 1.0) < 0.001)
        #expect(abs(ts.end - 2.0) < 0.001)
    }

    @Test("Throws on malformed timestamp")
    func throwsOnMalformedTimestamp() {
        #expect(throws: SubtitleTimestampError.self) {
            try SubtitleTimestamp(srtString: "not a timestamp")
        }
    }

    @Test("Throws on missing arrow separator")
    func throwsOnMissingSeparator() {
        #expect(throws: SubtitleTimestampError.self) {
            try SubtitleTimestamp(srtString: "00:00:01,000 00:00:02,000")
        }
    }

    @Test("Throws on empty string")
    func throwsOnEmptyString() {
        #expect(throws: SubtitleTimestampError.self) {
            try SubtitleTimestamp(srtString: "")
        }
    }

    // MARK: - Formatting to SRT string

    @Test("Formats to standard SRT string")
    func formatToSRT() {
        let ts = SubtitleTimestamp(start: 83.456, end: 85.789)
        #expect(ts.srtFormatted == "00:01:23,456 --> 00:01:25,789")
    }

    @Test("Formats zero values correctly")
    func formatZeroValues() {
        let ts = SubtitleTimestamp(start: 0, end: 0)
        #expect(ts.srtFormatted == "00:00:00,000 --> 00:00:00,000")
    }

    @Test("Formats hour-level values correctly")
    func formatHourValues() {
        let ts = SubtitleTimestamp(start: 9045.1, end: 9050.9)
        #expect(ts.srtFormatted == "02:30:45,100 --> 02:30:50,900")
    }

    // MARK: - Round-trip consistency

    @Test("Round-trip: parse then format preserves original")
    func roundTrip() throws {
        let original = "00:01:23,456 --> 00:01:25,789"
        let ts = try SubtitleTimestamp(srtString: original)
        #expect(ts.srtFormatted == original)
    }

    @Test("Round-trip: format then parse preserves values")
    func roundTripReverse() throws {
        let original = SubtitleTimestamp(start: 123.456, end: 789.012)
        let parsed = try SubtitleTimestamp(srtString: original.srtFormatted)
        #expect(abs(parsed.start - original.start) < 0.001)
        #expect(abs(parsed.end - original.end) < 0.001)
    }

    // MARK: - Duration

    @Test("Duration is end minus start")
    func duration() {
        let ts = SubtitleTimestamp(start: 10.0, end: 15.5)
        #expect(abs(ts.duration - 5.5) < 0.001)
    }

    // MARK: - Equatable

    @Test("Equal timestamps are equal")
    func equality() {
        let a = SubtitleTimestamp(start: 1.0, end: 2.0)
        let b = SubtitleTimestamp(start: 1.0, end: 2.0)
        #expect(a == b)
    }

    @Test("Different timestamps are not equal")
    func inequality() {
        let a = SubtitleTimestamp(start: 1.0, end: 2.0)
        let b = SubtitleTimestamp(start: 1.0, end: 3.0)
        #expect(a != b)
    }
}
