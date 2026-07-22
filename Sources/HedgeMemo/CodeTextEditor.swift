import AppKit
import HedgeMemoCore
import SwiftUI

/// A plain-text code editor with live syntax highlighting and inline keyword
/// completion, used in place of `TextEditor` when editing a code clipboard
/// entry. Completion is shown as dimmed "ghost text" after the caret (accepted
/// with Tab) rather than a floating popup — a popup would need its own window
/// and key handling, which fights the clipboard panel's window-wide key monitor
/// and click-outside dismissal.
struct CodeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var theme: CodeHighlightTheme
    var font: NSFont
    var showsScrollIndicators = true
    /// Invoked on Escape. In the clipboard panel a window monitor consumes
    /// Escape before the text view sees it, so this only fires in the pinned
    /// desktop note; passing a real handler in both places is harmless.
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 4)

        textView.baseFont = font
        textView.highlightTheme = theme
        textView.onCancel = onCancel
        textView.string = text
        textView.applyHighlighting()

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = showsScrollIndicators
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = textView

        context.coordinator.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? CodeNSTextView else { return }
        context.coordinator.parent = self
        scroll.hasVerticalScroller = showsScrollIndicators
        textView.baseFont = font
        textView.highlightTheme = theme
        textView.onCancel = onCancel
        // Only overwrite when the model diverges (e.g. an external reset), never
        // on the echo of the user's own edit, which would move the caret.
        if textView.string != text {
            textView.string = text
            textView.applyHighlighting()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeTextEditor
        weak var textView: CodeNSTextView?

        init(_ parent: CodeTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CodeNSTextView else { return }
            parent.text = textView.string
            textView.applyHighlighting()
            textView.refreshSuggestion()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? CodeNSTextView)?.refreshSuggestion()
        }
    }
}

/// The backing text view: owns highlighting, the ghost-text suggestion and the
/// Tab/Escape handling.
final class CodeNSTextView: NSTextView {
    var baseFont: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    var highlightTheme: CodeHighlightTheme = .system
    var onCancel: (() -> Void)?

    /// A pending inline completion: the partial word already typed (replaced on
    /// accept so the inserted word carries its own casing) plus the full word.
    private struct Suggestion: Equatable {
        let start: Int
        let typedLength: Int
        let word: String
        var replaceRange: NSRange { NSRange(location: start, length: typedLength) }
        /// The dimmed remainder drawn after the caret.
        var ghost: String { String(word.dropFirst(typedLength)) }
    }

    private var suggestion: Suggestion?

    /// Cached identifier tokens of the current text, rebuilt only when the text
    /// itself changes so that a selection change (arrow keys) reuses them.
    private var wordCacheSource: String?
    private var cachedTokens = InlineCodeCompletion.Tokens()

    func applyHighlighting() {
        guard let storage = textStorage else { return }
        CodeHighlighter.applyHighlighting(to: storage, baseFont: baseFont, theme: highlightTheme)
        typingAttributes[.font] = baseFont
    }

    // MARK: - Inline completion

    func refreshSuggestion() {
        let next = computeSuggestion()
        guard next != suggestion else { return }
        suggestion = next
        needsDisplay = true
    }

    private func computeSuggestion() -> Suggestion? {
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }
        let ns = string as NSString
        let caret = selection.location
        // Only complete at the trailing edge of a word.
        if caret < ns.length, isWordCharacter(ns.character(at: caret)) { return nil }
        var start = caret
        while start > 0, isWordCharacter(ns.character(at: start - 1)) { start -= 1 }
        let length = caret - start
        guard length >= 2 else { return nil }
        let partial = ns.substring(with: NSRange(location: start, length: length))
        // Identifiers only; never trigger on a run that begins with a digit.
        guard let firstScalar = partial.unicodeScalars.first,
              CharacterSet.letters.contains(firstScalar) || firstScalar == "_" else { return nil }

        let word = InlineCodeCompletion.completion(
            partial: partial,
            tokens: documentTokens(),
            keywords: CodeHighlighter.completionKeywords
        )
        guard let word else { return nil }
        return Suggestion(start: start, typedLength: length, word: word)
    }

    private func documentTokens() -> InlineCodeCompletion.Tokens {
        let current = string
        if wordCacheSource != current {
            wordCacheSource = current
            cachedTokens = InlineCodeCompletion.tokens(in: current)
        }
        return cachedTokens
    }

    private func acceptSuggestion() -> Bool {
        guard let suggestion, !suggestion.ghost.isEmpty else { return false }
        self.suggestion = nil
        // Replace the typed partial with the full word so a lowercase prefix is
        // corrected to the source identifier's real casing.
        insertText(suggestion.word, replacementRange: suggestion.replaceRange)
        return true
    }

    private func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || character == UInt16(UnicodeScalar("_").value)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48: // Tab — accept an active suggestion, otherwise indent.
            if acceptSuggestion() { return }
            insertText("\t", replacementRange: selectedRange())
            return
        case 53: // Escape — cancel editing; never let AppKit map it to completion.
            suggestion = nil
            needsDisplay = true
            onCancel?()
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let suffix = suggestion?.ghost, !suffix.isEmpty,
              let layoutManager, let container = textContainer else { return }
        let caret = selectedRange().location
        let inset = textContainerInset
        let origin: NSPoint
        if caret == 0 {
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: 0, length: 0), in: container)
            origin = NSPoint(x: rect.minX + inset.width, y: rect.minY + inset.height)
        } else {
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: caret - 1)
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: lastGlyph, length: 1), in: container)
            origin = NSPoint(x: rect.maxX + inset.width, y: rect.minY + inset.height)
        }
        (suffix as NSString).draw(at: origin, withAttributes: [
            .font: baseFont,
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }
}
