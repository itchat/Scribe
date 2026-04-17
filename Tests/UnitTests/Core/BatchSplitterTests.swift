import Testing
import Foundation
@testable import Domain
@testable import Core

@Suite("BatchSplitter")
struct BatchSplitterTests {

    private func makeEntry(id: Int, text: String) -> SubtitleEntry {
        SubtitleEntry(
            id: id,
            timestamp: SubtitleTimestamp(start: Double(id), end: Double(id) + 1.0),
            text: text
        )
    }

    @Test("Single entry stays in one batch")
    func singleEntry() {
        let entries = [makeEntry(id: 1, text: "Hello")]
        let batches = BatchSplitter.split(entries, maxChars: 1200, maxEntries: 100)
        #expect(batches.count == 1)
        #expect(batches[0].count == 1)
    }

    @Test("Empty input returns empty batches")
    func emptyInput() {
        let batches = BatchSplitter.split([], maxChars: 1200, maxEntries: 100)
        #expect(batches.isEmpty)
    }

    @Test("Splits when max entries exceeded")
    func splitsOnEntryCount() {
        let entries = (1...5).map { makeEntry(id: $0, text: "Short") }
        let batches = BatchSplitter.split(entries, maxChars: 10000, maxEntries: 2)
        #expect(batches.count == 3) // [2, 2, 1]
        #expect(batches[0].count == 2)
        #expect(batches[1].count == 2)
        #expect(batches[2].count == 1)
    }

    @Test("Splits when max chars exceeded")
    func splitsOnCharCount() {
        let entries = [
            makeEntry(id: 1, text: String(repeating: "a", count: 500)),
            makeEntry(id: 2, text: String(repeating: "b", count: 500)),
            makeEntry(id: 3, text: String(repeating: "c", count: 500)),
        ]
        let batches = BatchSplitter.split(entries, maxChars: 800, maxEntries: 100)
        // 500 fits, 500+500=1000 > 800, so split after first. Then 500 fits, 500+500>800, split.
        #expect(batches.count == 3)
    }

    @Test("Large single entry gets its own batch")
    func largeSingleEntry() {
        let entries = [
            makeEntry(id: 1, text: String(repeating: "x", count: 2000)),
            makeEntry(id: 2, text: "short"),
        ]
        let batches = BatchSplitter.split(entries, maxChars: 1200, maxEntries: 100)
        #expect(batches.count == 2)
        #expect(batches[0].count == 1)
        #expect(batches[1].count == 1)
    }

    @Test("All entries fit in one batch when under limits")
    func allFitInOne() {
        let entries = (1...10).map { makeEntry(id: $0, text: "Hi") }
        let batches = BatchSplitter.split(entries, maxChars: 1200, maxEntries: 100)
        #expect(batches.count == 1)
        #expect(batches[0].count == 10)
    }

    @Test("Uses default constants when no limits specified")
    func defaultLimits() {
        let entries = [makeEntry(id: 1, text: "Hello")]
        let batches = BatchSplitter.split(entries)
        #expect(batches.count == 1)
    }
}
