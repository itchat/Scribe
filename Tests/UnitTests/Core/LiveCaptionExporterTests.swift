import Testing
import Foundation
@testable import Domain
@testable import Core

/// Export coverage for the Live Captions transcript.
///
/// Untested until now, and the behaviour it guards was silently broken: with
/// cumulative updates the view model's `history` only ever received a single
/// entry (engines set `isFinal` once, from `finish()`), so SRT export always
/// produced exactly one cue spanning the whole session. Now that engines
/// commit per utterance these assertions describe what a user actually gets.
@Suite("LiveCaptionExporter")
struct LiveCaptionExporterTests {

    private static let sessionStart = Date(timeIntervalSince1970: 1_000_000)

    private static func entries(_ specs: [(String, TimeInterval)]) -> [LiveCaptionEntry] {
        specs.map { text, offset in
            LiveCaptionEntry(text: text, emittedAt: sessionStart.addingTimeInterval(offset))
        }
    }

    // MARK: - SRT

    @Test("Emits one cue per finalized utterance")
    func oneCuePerUtterance() throws {
        let srt = LiveCaptionExporter.srt(
            entries: Self.entries([("first line", 4), ("second line", 9), ("third line", 14)]),
            sessionStart: Self.sessionStart
        )
        // Cue indices appear at the start of their own line.
        #expect(srt.contains("1\n"))
        #expect(srt.contains("2\n"))
        #expect(srt.contains("3\n"))
        #expect(srt.contains("first line"))
        #expect(srt.contains("second line"))
        #expect(srt.contains("third line"))

        let parsed = try SRTParser.parse(srt)
        #expect(parsed.count == 3, "expected 3 cues, got \(parsed.count)")
    }

    @Test("Cues are ordered and non-overlapping")
    func cuesAreMonotonic() throws {
        let srt = LiveCaptionExporter.srt(
            entries: Self.entries([("a", 3), ("b", 6), ("c", 10), ("d", 11)]),
            sessionStart: Self.sessionStart
        )
        let parsed = try SRTParser.parse(srt)
        #expect(parsed.count == 4)

        for cue in parsed {
            #expect(cue.timestamp.end > cue.timestamp.start, "cue \(cue.id) has non-positive duration")
        }
        for (previous, next) in zip(parsed, parsed.dropFirst()) {
            #expect(next.timestamp.start >= previous.timestamp.end,
                    "cue \(next.id) starts before cue \(previous.id) ends")
        }
    }

    /// Entries arriving in the same instant must still yield a visible window
    /// rather than a zero-length cue that players skip.
    @Test("Gives simultaneous entries a non-zero on-screen window")
    func simultaneousEntriesStillVisible() throws {
        let srt = LiveCaptionExporter.srt(
            entries: Self.entries([("x", 5), ("y", 5), ("z", 5)]),
            sessionStart: Self.sessionStart
        )
        let parsed = try SRTParser.parse(srt)
        #expect(parsed.count == 3)
        for cue in parsed {
            #expect(cue.timestamp.end - cue.timestamp.start >= 0.5)
        }
    }

    @Test("Single entry gets the fallback duration")
    func singleEntryFallback() throws {
        let srt = LiveCaptionExporter.srt(
            entries: Self.entries([("only line", 10)]),
            sessionStart: Self.sessionStart
        )
        let parsed = try SRTParser.parse(srt)
        #expect(parsed.count == 1)
        let cue = try? #require(parsed.first)
        if let cue {
            #expect(abs((cue.timestamp.end - cue.timestamp.start)
                        - LiveCaptionExporter.singleEntryFallbackDuration) < 0.01)
        }
    }

    @Test("Empty history exports nothing")
    func emptyExportsNothing() {
        #expect(LiveCaptionExporter.srt(entries: [], sessionStart: Self.sessionStart).isEmpty)
        #expect(LiveCaptionExporter.plainText(entries: []).isEmpty)
    }

    // MARK: - Plain text / clipboard

    /// Flowed, not line-per-entry — an entry is an utterance, and a
    /// VAD-driven engine ends utterances mid-sentence. SRT keeps per-entry
    /// cues; readable text does not.
    @Test("Plain text flows utterances into prose")
    func plainTextFlows() {
        let text = LiveCaptionExporter.plainText(
            entries: Self.entries([("one.", 1), ("two.", 2), ("three.", 3)])
        )
        #expect(text == "one. two. three.")
    }

    @Test("Plain text needs no spaces between Chinese utterances")
    func plainTextFlowsChinese() {
        let text = LiveCaptionExporter.plainText(
            entries: Self.entries([("回答的是。", 1), ("是谁?", 2), ("文明回答的是。", 3)])
        )
        #expect(text == "回答的是。是谁?文明回答的是。")
    }

    @Test("Clipboard appends the in-progress line")
    func clipboardIncludesCurrent() {
        let text = LiveCaptionExporter.clipboardString(
            entries: Self.entries([("settled.", 1)]),
            current: "  in progress  "
        )
        #expect(text == "settled. in progress")
    }

    @Test("Clipboard omits a blank in-progress line")
    func clipboardSkipsBlankCurrent() {
        let text = LiveCaptionExporter.clipboardString(
            entries: Self.entries([("settled", 1)]),
            current: "   \n "
        )
        #expect(text == "settled")
    }
}
