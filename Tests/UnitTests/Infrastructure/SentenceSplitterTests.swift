import Testing
import Foundation
@testable import Infrastructure

/// Verifies the shared sentence splitter that both `FluidAudioRecognizer`
/// (English-only) and `Qwen3OfflineRecognizer` (Chinese + English mixed)
/// rely on for fallback segment timing.
@Suite("SentenceSplitter")
struct SentenceSplitterTests {

    @Test("ASCII terminators split on ., !, ?")
    func englishTerminators() {
        let result = SentenceSplitter.split("Hi. Bye! Right?")
        #expect(result == ["Hi.", "Bye!", "Right?"])
    }

    @Test("Full-width Chinese terminators split on 。 ！ ？")
    func chineseTerminators() {
        let result = SentenceSplitter.split("你好。再见！懂吗？")
        #expect(result == ["你好。", "再见！", "懂吗？"])
    }

    @Test("Code-switching content splits at any terminator regardless of language")
    func codeSwitchingMixed() {
        let result = SentenceSplitter.split("Today 我 deploy 了 a new feature。完成了！")
        #expect(result.count == 2)
        #expect(result[0].contains("deploy"))
        #expect(result[0].contains("我"))
        #expect(result[1].contains("完成"))
    }

    @Test("Empty input returns single empty fallback")
    func emptyString() {
        let result = SentenceSplitter.split("")
        #expect(result == [""])
    }

    @Test("Input without any terminator is returned as one segment")
    func noTerminator() {
        let result = SentenceSplitter.split("Just a fragment")
        #expect(result == ["Just a fragment"])
    }

    @Test("Whitespace around segments is trimmed")
    func trimsWhitespace() {
        let result = SentenceSplitter.split("  First.   Second.  ")
        #expect(result == ["First.", "Second."])
    }
}
