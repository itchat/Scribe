import SwiftUI
import AppKit
import Domain

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

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let attributed = Self.makeAttributed(history: history, currentCaption: currentCaption)
        // Only rebuild if the visible text actually changed — avoids
        // wiping the user's in-progress selection on every partial.
        let oldText = textView.attributedString().string
        let newText = attributed.string
        guard oldText != newText else { return }

        let wasNearBottom = Self.isScrolledNearBottom(scrollView)
        textView.textStorage?.setAttributedString(attributed)

        if wasNearBottom {
            // Defer scroll to next runloop so AppKit has settled the new
            // layout before we ask it for the trailing position.
            DispatchQueue.main.async {
                textView.scrollToEndOfDocument(nil)
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        private let onSelectionChange: (String) -> Void
        private var lastReported: String = ""

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
        let historyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle,
        ]
        let liveAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ]
        for entry in history {
            result.append(NSAttributedString(string: entry.text + "\n", attributes: historyAttrs))
        }
        let trimmedLive = currentCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLive.isEmpty {
            result.append(NSAttributedString(string: trimmedLive, attributes: liveAttrs))
        }
        return result
    }

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
