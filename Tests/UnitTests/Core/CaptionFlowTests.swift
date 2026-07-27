import Testing
import Foundation
@testable import Domain
@testable import Core

/// How finalized utterances are joined for reading.
///
/// Engines commit one entry per utterance so SRT gets one cue per utterance,
/// but Qwen3's VAD splits on ordinary mid-sentence pauses and the model
/// punctuates each fragment as a sentence. Rendering one entry per line turned
/// continuous speech into a column of stubs; these tests pin the flowing
/// behaviour that replaced it.
@Suite("CaptionFlow")
struct CaptionFlowTests {

    private func entries(_ texts: [String]) -> [LiveCaptionEntry] {
        texts.enumerated().map { index, text in
            LiveCaptionEntry(text: text, emittedAt: Date(timeIntervalSince1970: 1000 + Double(index)))
        }
    }

    // MARK: - CJK

    /// The exact fragments from the reported bug. They are one thought and
    /// must read as one run, not nine lines.
    @Test("Flows Chinese fragments into continuous text")
    func flowsChineseFragments() {
        let joined = CaptionFlow.joined(entries([
            "回答的是。",
            "是谁?",
            "文明回答的是。",
            "如何面对那些不是我们的人?",
        ]))
        #expect(joined == "回答的是。是谁?文明回答的是。如何面对那些不是我们的人?")
        #expect(!joined.contains("\n"), "flowed text must not contain line breaks")
    }

    @Test("Inserts no space after full-width punctuation")
    func noSpaceAfterFullWidthPunctuation() {
        #expect(CaptionFlow.separator(after: "成规模更大的文化。", before: "历史更悠久的文化。") == "")
        #expect(CaptionFlow.separator(after: "但是，", before: "只是概念上的细微区别。") == "")
        #expect(CaptionFlow.separator(after: "是谁？", before: "文明回答的是。") == "")
    }

    @Test("Inserts no space between bare CJK characters")
    func noSpaceBetweenCJK() {
        #expect(CaptionFlow.separator(after: "中文", before: "继续") == "")
    }

    @Test("Inserts no space before an opening full-width bracket")
    func noSpaceBeforeOpeningPunctuation() {
        #expect(CaptionFlow.separator(after: "他说", before: "「你好」") == "")
    }

    // MARK: - Latin

    @Test("Separates English sentences with a single space")
    func spacesEnglish() {
        let joined = CaptionFlow.joined(entries([
            "This is the first sentence.",
            "And here is the second.",
        ]))
        #expect(joined == "This is the first sentence. And here is the second.")
    }

    @Test("Does not double up when a fragment already has surrounding space")
    func trimsBeforeJoining() {
        let joined = CaptionFlow.joined(entries(["  leading and trailing  ", "  next  "]))
        #expect(joined == "leading and trailing next")
    }

    // MARK: - Mixed

    /// Code-switched speech is the common case for the Qwen3 engines.
    @Test("Handles a Chinese/English boundary in both directions")
    func mixedScriptBoundaries() {
        // CJK then Latin: the CJK side governs, so no space is inserted.
        #expect(CaptionFlow.separator(after: "这是中文。", before: "Now English.") == "")
        // Latin then CJK: likewise no space, since CJK does not take one.
        #expect(CaptionFlow.separator(after: "English text", before: "中文继续") == "")
    }

    // MARK: - Degenerate input

    @Test("Empty history joins to an empty string")
    func emptyHistory() {
        #expect(CaptionFlow.joined([]).isEmpty)
    }

    @Test("Skips blank entries entirely")
    func skipsBlankEntries() {
        let joined = CaptionFlow.joined(entries(["First.", "   ", "\n", "Second."]))
        #expect(joined == "First. Second.")
    }

    @Test("A single entry is returned unchanged")
    func singleEntry() {
        #expect(CaptionFlow.joined(entries(["  only one  "])) == "only one")
    }

    @Test("Separator is empty when either side is blank")
    func blankSides() {
        #expect(CaptionFlow.separator(after: "", before: "text") == "")
        #expect(CaptionFlow.separator(after: "text", before: "") == "")
    }

    /// The incremental renderer appends `separator + text` per entry and must
    /// land on exactly the same string as a full rebuild, or its length
    /// bookkeeping desynchronises and every update degrades to a full rebuild.
    @Test("Incremental application matches the batch join")
    func incrementalMatchesBatch() {
        let texts = ["回答的是。", "是谁?", "Then English.", "And more.", "再来中文。"]
        let batch = CaptionFlow.joined(entries(texts))

        var incremental = ""
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if incremental.isEmpty {
                incremental = trimmed
            } else {
                incremental += CaptionFlow.separator(after: incremental, before: trimmed) + trimmed
            }
        }
        #expect(incremental == batch)
    }
}
