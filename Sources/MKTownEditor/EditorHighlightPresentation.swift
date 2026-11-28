import AppKit

/// Presentation state only. TextKit's content, selection attributes, and Undo are left to the editor.
@MainActor
final class EditorHighlightPresentation {
    private var settings = EditorHighlightSettings()
    private var palette = EditorThemePalette.navy
    private var previousSelection: NSRange?
    private var currentLineRevision = -1
    private var pendingBracket: Int?
    private var bracketTask: Task<Void, Never>?
    private var wordTask: Task<Void, Never>?
    private(set) var currentLine: NSRange?
    private(set) var matchingBracket: NSRange?
    private(set) var selectedWord: String?

    var hasHighlights: Bool {
        currentLine != nil || hasMarks
    }

    var hasMarks: Bool {
        matchingBracket != nil || selectedWord != nil
    }

    func configure(_ settings: EditorHighlightSettings, palette: EditorThemePalette, in view: EditorTextView) {
        if self.palette != palette {
            self.palette = palette
            if hasHighlights { view.needsDisplay = true }
        }
        guard self.settings != settings else {
            if let pendingBracket { showMatchingBracket(at: pendingBracket, in: view) }
            return
        }
        self.settings = settings
        clearSelection(in: view)
        if !settings.currentLine, currentLine != nil {
            currentLine = nil
            view.needsDisplay = true
        }
        updateSelection(in: view, matchesCrossedBracket: false)
    }

    func clearSelection(in view: EditorTextView) {
        previousSelection = nil
        clearTransientHighlights(in: view)
    }

    private func clearTransientHighlights(in view: EditorTextView) {
        pendingBracket = nil
        bracketTask?.cancel()
        bracketTask = nil
        wordTask?.cancel()
        wordTask = nil
        if matchingBracket != nil || selectedWord != nil { view.needsDisplay = true }
        matchingBracket = nil
        selectedWord = nil
    }

    func updateSelection(in view: EditorTextView, matchesCrossedBracket: Bool) {
        guard settings.currentLine || settings.matchingBrackets || settings.selectedWord,
              let source = view.textStorage?.mutableString else { return }
        let selections = view.selectedRanges
        let selection = selections.count == 1 ? selections.first?.rangeValue : nil
        updateCurrentLine(for: selection, source: source, in: view)

        if view.hasMarkedText() {
            clearSelection(in: view)
            return
        }
        guard selection != previousSelection else { return }
        let previous = previousSelection
        previousSelection = selection
        clearTransientHighlights(in: view)
        guard let selection else { return }

        if selection.length == 0, settings.matchingBrackets, matchesCrossedBracket,
           let previous, previous.length == 0,
           let crossed = EditorHighlightMatching.crossedBracket(
               in: source, from: previous.location, to: selection.location) {
            showMatchingBracket(at: crossed, in: view)
        }
        if selection.length > 0, settings.selectedWord {
            scheduleSelectedWord(for: selection, in: view)
        }
    }

    private func updateCurrentLine(for selection: NSRange?, source: NSString, in view: EditorTextView) {
        let previous = currentLine
        defer {
            // TextKit already invalidates the affected fragments when typing in the same logical line.
            // If the caret moves to a different logical line, repaint the old fill as well as the new one.
            if previous?.location != currentLine?.location { view.needsDisplay = true }
            currentLineRevision = view.sourceRevision
        }
        guard settings.currentLine, let selection, selection.length == 0,
              selection.location <= source.length else {
            currentLine = nil
            return
        }
        if currentLineRevision == view.sourceRevision, let previous,
           previous == selection || NSLocationInRange(selection.location, previous) { return }
        currentLine = source.lineRange(for: selection)
    }

    private func showMatchingBracket(at location: Int, in view: EditorTextView) {
        let snapshot = view.commandModel?.matchingSnapshot
        if view.commandModel?.usesSharedAnalysis == true, snapshot == nil {
            // The document analysis store already has this source queued.
            pendingBracket = location
            return
        }
        pendingBracket = nil
        let source = view.sourceText
        let dialect = view.commandModel?.markdownDialect ?? .extended
        bracketTask = Task { [weak self, weak view] in
            // Unmatched brackets can require scanning a large part of the document.
            let lookup = Task.detached(priority: .userInitiated) { () -> NSRange? in
                guard !Task.isCancelled else { return nil }
                let analysis = snapshot?.analysis ?? MarkdownAnalysis(source, dialect: dialect)
                let inlineCode = snapshot?.inlineCodeRanges ?? MarkdownInlineSyntax.codeSpanRanges(in: source)
                let blocks = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
                let codeRanges = blocks + inlineCode.filter {
                    !MarkdownInlineSyntax.intersects($0, sortedRanges: blocks)
                }
                return EditorHighlightMatching.matchingBracket(in: source as NSString, at: location,
                    codeRanges: codeRanges, isCancelled: { Task.isCancelled })
            }
            let match = await withTaskCancellationHandler {
                await lookup.value
            } onCancel: {
                lookup.cancel()
            }
            guard !Task.isCancelled, let match else { return }
            self?.matchingBracket = match
            view?.needsDisplay = true
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.matchingBracket = nil
            view?.needsDisplay = true
        }
    }

    private func scheduleSelectedWord(for selection: NSRange, in view: EditorTextView) {
        let delay = settings.wordDelay
        wordTask = Task { [weak self, weak view] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let view, !view.hasMarkedText(),
                  view.selectedRanges.count == 1, view.selectedRange() == selection,
                  let source = view.textStorage?.mutableString,
                  let word = EditorHighlightMatching.selectedWord(in: source, selection: selection) else { return }
            self?.selectedWord = word
            view.needsDisplay = true
        }
    }

    func drawCurrentLine(in dirtyRect: NSRect, textView: EditorTextView,
                         layoutManager: NSLayoutManager, textContainer: NSTextContainer) {
        guard let currentLine else { return }
        let origin = textView.textContainerOrigin
        // A partial redraw can be entirely to the right of the line's text.
        let band = NSRect(x: textView.bounds.minX - origin.x, y: dirtyRect.minY - origin.y,
                          width: textView.bounds.width, height: dirtyRect.height)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: band, in: textContainer)
        palette.currentLineHighlight.setFill()
        func fillLine(_ fragment: NSRect) {
            let row = NSRect(x: dirtyRect.minX, y: fragment.minY + origin.y,
                             width: dirtyRect.width, height: fragment.height)
            row.intersection(dirtyRect).fill()
        }
        if currentLine.length == 0 {
            if layoutManager.extraLineFragmentTextContainer === textContainer {
                fillLine(layoutManager.extraLineFragmentRect)
            }
            return
        }
        let visible = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let intersection = NSIntersectionRange(currentLine, visible)
        guard intersection.length > 0 else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: intersection, actualCharacterRange: nil)
        layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in
            fillLine(fragment)
        }
    }

    func drawMarks(visible: NSRange, textView: EditorTextView,
                   layoutManager: NSLayoutManager, textContainer: NSTextContainer) {
        let origin = textView.textContainerOrigin
        func drawMark(for range: NSRange, fill: NSColor, outline: NSColor? = nil) {
            let intersection = NSIntersectionRange(range, visible)
            guard intersection.length > 0 else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: intersection, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
                let frame = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0.5, dy: 0.5)
                guard frame.width > 0, frame.height > 0 else { return }
                let path = NSBezierPath(roundedRect: frame, xRadius: 2, yRadius: 2)
                fill.setFill()
                path.fill()
                if let outline {
                    outline.setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
            }
        }

        if let selectedWord, let source = textView.textStorage?.mutableString, visible.length > 0 {
            let selection = textView.selectedRange()
            for range in EditorHighlightMatching.wordOccurrences(in: source, word: selectedWord, within: visible)
                where range != selection {
                drawMark(for: range, fill: palette.selectedWordHighlight)
            }
        }
        if let matchingBracket {
            drawMark(for: matchingBracket, fill: palette.matchingBracketBackground,
                     outline: palette.matchingBracketOutline)
        }
    }
}
