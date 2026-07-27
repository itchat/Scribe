import SwiftUI
import AppKit
import Domain
import Core

/// AppKit-backed selectable transcript pane for the Live Captions
/// window. SwiftUI's `Text(...).textSelection(.enabled)` lets the user
/// copy but doesn't expose the selected substring programmatically;
/// for an "instant translate selection" popup we need that hook, which
/// only `NSTextView` provides on macOS.
///
/// Layout: read-only NSTextView inside an NSScrollView. Confirmed
/// history lines render in secondary text colour (matches the prior
/// SwiftUI styling); the in-progress live partial renders bright in
/// primary colour. Selection changes fire `onSelectionChange` (debounced
/// at the call site so rapid updates don't spam the translator).
struct SelectableTranscriptView: NSViewRepresentable {

    let history: [LiveCaptionEntry]
    let currentCaption: String
    let onSelectionChange: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelectionChange: onSelectionChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 20, height: 20)
        textView.delegate = context.coordinator
        textView.allowsUndo = false
        // Wrap to view width so the scrollview only scrolls vertically.
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // Sensible defaults — system font, line spacing slightly looser
        // than the AppKit default reads better for long passages.
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.defaultParagraphStyle = Self.paragraphStyle

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    /// Applies the smallest edit that brings the text view up to date.
    ///
    /// The previous version rebuilt the entire transcript, materialised the
    /// whole document as a `String` to compare against it, and then called
    /// `setAttributedString` — a full TextKit relayout — on every partial.
    /// Because the old update model made `currentCaption` hold the *entire*
    /// session transcript, that ran several times a second over a document
    /// that grew all session. It also wiped the user's selection roughly once
    /// a second, which is fatal for select-to-translate: the guard above only
    /// skipped when the text was unchanged, which never happens while
    /// captions stream.
    ///
    /// Now history lines are append-only and only the short trailing live run
    /// is rewritten, so the cost is proportional to what changed.
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        let coordinator = context.coordinator

        let selection = textView.selectedRange()
        let liveRange = NSRange(location: coordinator.committedLength, length: coordinator.liveLength)

        // Editing the live run would destroy a selection that overlaps it.
        // Skip this cycle instead; the next update catches up once the user
        // has finished with the selection.
        if selection.length > 0, NSIntersectionRange(selection, liveRange).length > 0 {
            return
        }

        let wasNearBottom = Self.isScrolledNearBottom(scrollView)

        // Anything that invalidates our incremental bookkeeping — history
        // cleared, trimmed at the cap, or the storage mutated behind us —
        // falls back to a full rebuild.
        let bookkeepingValid = history.count >= coordinator.renderedHistoryCount
            && storage.length == coordinator.committedLength + coordinator.liveLength
        guard bookkeepingValid else {
            let attributed = Self.makeAttributed(history: history, currentCaption: currentCaption)
            storage.setAttributedString(attributed)
            coordinator.renderedHistoryCount = history.count
            coordinator.committedLength = Self.committedLength(of: history)
            coordinator.liveLength = storage.length - coordinator.committedLength
            coordinator.renderedTail = Self.renderedTail(of: history)
            coordinator.renderedLive = currentCaption.trimmingCharacters(in: .whitespacesAndNewlines)
            Self.scrollIfNeeded(textView, wasNearBottom: wasNearBottom)
            return
        }

        let newLive = currentCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNewHistory = history.count > coordinator.renderedHistoryCount
        let liveChanged = newLive != coordinator.renderedLive
        guard hasNewHistory || liveChanged else { return }

        storage.beginEditing()

        // Drop the old live run so new history lands before it.
        if coordinator.liveLength > 0 {
            storage.replaceCharacters(in: liveRange, with: "")
            coordinator.liveLength = 0
        }

        if hasNewHistory {
            for entry in history[coordinator.renderedHistoryCount...] {
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                // Flow into running text rather than one line per entry —
                // see `CaptionFlow` for why an utterance is not a line.
                let separator = coordinator.renderedTail.isEmpty
                    ? ""
                    : CaptionFlow.separator(after: coordinator.renderedTail, before: text)
                let run = NSAttributedString(
                    string: separator + text,
                    attributes: Self.historyAttributes
                )
                storage.append(run)
                coordinator.committedLength += run.length
                coordinator.renderedTail = text
            }
            coordinator.renderedHistoryCount = history.count
        }

        if !newLive.isEmpty {
            let separator = coordinator.renderedTail.isEmpty
                ? ""
                : CaptionFlow.separator(after: coordinator.renderedTail, before: newLive)
            let run = NSAttributedString(string: separator + newLive, attributes: Self.liveAttributes)
            storage.append(run)
            coordinator.liveLength = run.length
        }
        coordinator.renderedLive = newLive

        storage.endEditing()

        // The committed prefix never moves, so a selection inside it stays
        // valid; restore it explicitly since AppKit may still have reset it.
        if selection.length > 0, selection.location + selection.length <= coordinator.committedLength {
            textView.setSelectedRange(selection)
        }

        Self.scrollIfNeeded(textView, wasNearBottom: wasNearBottom)
    }

    private static func scrollIfNeeded(_ textView: NSTextView, wasNearBottom: Bool) {
        guard wasNearBottom else { return }
        // Defer scroll to next runloop so AppKit has settled the new
        // layout before we ask it for the trailing position.
        DispatchQueue.main.async {
            textView.scrollToEndOfDocument(nil)
        }
    }

    /// UTF-16 length the flowed history occupies. Must match exactly what
    /// `makeAttributed` produced, or the incremental path's bookkeeping check
    /// fails and every update degrades to a full rebuild.
    private static func committedLength(of history: [LiveCaptionEntry]) -> Int {
        (CaptionFlow.joined(history) as NSString).length
    }

    /// Trailing committed utterance after a full rebuild.
    private static func renderedTail(of history: [LiveCaptionEntry]) -> String {
        history.last { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        private let onSelectionChange: (String) -> Void
        private var lastReported: String = ""

        // Incremental-rendering bookkeeping. See `updateNSView`.
        /// History entries already written into the text storage.
        var renderedHistoryCount = 0
        /// Characters occupied by those entries (the immutable prefix).
        var committedLength = 0
        /// Characters occupied by the trailing in-progress run.
        var liveLength = 0
        /// Text of that run, so an unchanged partial is a no-op.
        var renderedLive = ""
        /// Last committed utterance, so the next one can pick the right
        /// separator without re-reading the storage.
        var renderedTail = ""

        init(onSelectionChange: @escaping (String) -> Void) {
            self.onSelectionChange = onSelectionChange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            let text: String
            if range.length > 0,
               let storage = textView.textStorage,
               range.location + range.length <= storage.length {
                text = (storage.string as NSString).substring(with: range)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = ""
            }
            // De-duplicate: zero-length → ""; same selected text twice → skip.
            guard text != lastReported else { return }
            lastReported = text
            onSelectionChange(text)
        }
    }

    // MARK: - Attributed string builder

    /// Builds the full transcript as a single `NSAttributedString` so
    /// selection naturally spans across history rows + the live partial.
    private static func makeAttributed(
        history: [LiveCaptionEntry],
        currentCaption: String
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let committed = CaptionFlow.joined(history)
        if !committed.isEmpty {
            result.append(NSAttributedString(string: committed, attributes: historyAttributes))
        }
        let trimmedLive = currentCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLive.isEmpty {
            let separator = committed.isEmpty
                ? ""
                : CaptionFlow.separator(after: committed, before: trimmedLive)
            result.append(NSAttributedString(string: separator + trimmedLive, attributes: liveAttributes))
        }
        return result
    }

    /// Settled lines. Rendered in the primary label colour — this is the text
    /// the reader actually dwells on, so it should not be the dimmer of the
    /// two (it previously used `secondaryLabelColor` while the transient
    /// partial got full contrast).
    static let historyAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.preferredFont(forTextStyle: .body),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: paragraphStyle,
    ]

    /// The in-progress line, de-emphasised because it is still changing.
    static let liveAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.preferredFont(forTextStyle: .body),
        .foregroundColor: NSColor.secondaryLabelColor,
        .paragraphStyle: paragraphStyle,
    ]

    private static let paragraphStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        p.paragraphSpacing = 4
        return p
    }()

    /// Returns true when the user is reading the tail of the transcript
    /// — used to decide whether to auto-scroll on new content. If the
    /// user has scrolled up to read older lines we leave their position
    /// alone.
    private static func isScrolledNearBottom(_ scrollView: NSScrollView) -> Bool {
        let clip = scrollView.contentView
        guard let docView = scrollView.documentView else { return true }
        let docHeight = docView.frame.height
        let visibleBottom = clip.bounds.origin.y + clip.bounds.size.height
        return docHeight - visibleBottom < 50
    }
}
