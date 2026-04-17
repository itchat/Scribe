import Foundation
import Domain

/// Writes subtitle entries to SRT-format text.
///
/// SRP: Only responsible for [SubtitleEntry] → SRT text.
public enum SRTWriter {

    /// Write entries to SRT format.
    /// - Parameter bilingual: If true, uses `bilingualText` (original + translated).
    ///   If false, uses `text` only.
    public static func write(_ entries: [SubtitleEntry], bilingual: Bool = false) -> String {
        guard !entries.isEmpty else { return "" }

        var output = ""
        for entry in entries {
            let text = bilingual ? entry.bilingualText : entry.text
            output += "\(entry.id)\n"
            output += "\(entry.timestamp.srtFormatted)\n"
            output += "\(text)\n"
            output += "\n"
        }
        return output
    }
}
