import AppKit

struct MarkdownLineNumberIndex {
    private(set) var starts: [Int]
    private(set) var length: Int

    init(_ text: String) {
        let source = text as NSString
        var result = [0]
        var offset = 0
        while offset < source.length {
            switch source.character(at: offset) {
            case 13:
                if offset + 1 < source.length && source.character(at: offset + 1) == 10 {
                    offset += 1
                }
                result.append(offset + 1)
            case 10:
                result.append(offset + 1)
            default: break
            }
            offset += 1
        }
        starts = result
        length = source.length
    }

    /// Rescan only the edited lines and their CR/LF boundary neighbors.
    mutating func update(in source: NSString, editedRange: NSRange, changeInLength delta: Int) {
        let oldEnd = NSMaxRange(editedRange) - delta
        let startPosition = max(0, editedRange.location - 1)
        let startIndex = max(0, upperBound(startPosition) - 1)
        let start = starts[startIndex]
        let endIndex = upperBound(min(length, oldEnd + 1))
        let oldBoundary = endIndex < starts.count ? starts[endIndex] : length
        let newBoundary = min(source.length, max(start, oldBoundary + delta))
        let local = MarkdownLineNumberIndex(source.substring(with:
            NSRange(location: start, length: newBoundary - start)))
        let suffix = starts.dropFirst(endIndex).filter { $0 > oldBoundary }.map { $0 + delta }
        starts = Array(starts.prefix(startIndex)) + local.starts.map { $0 + start } + suffix
        length = source.length
    }

    private func upperBound(_ location: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= location { low = middle + 1 } else { high = middle }
        }
        return low
    }

    func number(atFragmentStart location: Int) -> Int? {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] < location { low = middle + 1 } else { high = middle }
        }
        return low < starts.count && starts[low] == location ? low + 1 : nil
    }
}

struct MarkdownLineNumberLabel {
    let number: Int
    let origin: NSPoint
    let height: CGFloat
}

@MainActor
enum MarkdownLineNumberLayout {
    static func labels(in textView: NSTextView, visibleRect: NSRect,
                       cachedIndex: MarkdownLineNumberIndex? = nil) -> [MarkdownLineNumberLabel] {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let index = cachedIndex ?? MarkdownLineNumberIndex(textView.editorSource)
        if index.length == 0 {
            let origin = textView.textContainerOrigin
            let height = manager.defaultLineHeight(for: textView.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize))
            return NSRect(origin: origin, size: NSSize(width: 1, height: height)).intersects(visibleRect)
                ? [MarkdownLineNumberLabel(number: 1, origin: origin, height: height)] : []
        }
        let containerRect = visibleRect.offsetBy(dx: -textView.textContainerOrigin.x,
                                                 dy: -textView.textContainerOrigin.y)
        let glyphs = manager.glyphRange(forBoundingRect: containerRect, in: container)
        var labels: [MarkdownLineNumberLabel] = []
        manager.enumerateLineFragments(forGlyphRange: glyphs) { rectangle, _, _, glyphRange, _ in
            let characters = manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard let number = index.number(atFragmentStart: characters.location) else { return }
            let origin = NSPoint(x: textView.textContainerOrigin.x + rectangle.minX,
                                 y: textView.textContainerOrigin.y + rectangle.minY)
            labels.append(MarkdownLineNumberLabel(number: number, origin: origin,
                                                  height: rectangle.height))
        }

        if index.starts.last == index.length {
            let extra = manager.extraLineFragmentRect
            if extra.height > 0 {
                let origin = NSPoint(x: textView.textContainerOrigin.x + extra.minX,
                                     y: textView.textContainerOrigin.y + extra.minY)
                if NSRect(origin: origin, size: extra.size).intersects(visibleRect) {
                    labels.append(MarkdownLineNumberLabel(number: index.starts.count,
                                                          origin: origin, height: extra.height))
                }
            }
        }
        return labels
    }
}

@MainActor
final class MarkdownLineNumberRulerView: NSRulerView {
    private weak var editor: NSTextView?
    private(set) var index: MarkdownLineNumberIndex

    init(scrollView: NSScrollView, editor: NSTextView) {
        self.editor = editor
        index = MarkdownLineNumberIndex(editor.editorSource)
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        NotificationCenter.default.addObserver(self, selector: #selector(storageDidChange(_:)),
            name: NSTextStorage.didProcessEditingNotification, object: editor.textStorage)
        setAccessibilityLabel("行番号")
        refresh()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func storageDidChange(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedCharacters) else { return }
        index.update(in: storage.string as NSString, editedRange: storage.editedRange,
                     changeInLength: storage.changeInLength)
        refresh()
    }

    func refresh() {
        let digits = String(index.starts.count).count
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                   weight: .regular)
        let width = (String(repeating: "8", count: digits) as NSString)
            .size(withAttributes: [.font: font]).width
        ruleThickness = ceil(width) + 24
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let editor else { return }
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                   weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let lineStarts = index.starts
        let foldedLocations = (editor as? EditorTextView)?.foldedHeaderLocations ?? []
        for label in MarkdownLineNumberLayout.labels(in: editor, visibleRect: editor.visibleRect, cachedIndex: index) {
            let point = convert(label.origin, from: editor)
            if label.number <= lineStarts.count,
               foldedLocations.contains(lineStarts[label.number - 1]) {
                ("▶" as NSString).draw(at: NSPoint(x: 3,
                    y: point.y + (label.height - font.pointSize) / 2),
                    withAttributes: attributes)
            }
            let text = String(label.number) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: ruleThickness - size.width - 9,
                                  y: point.y + (label.height - size.height) / 2),
                      withAttributes: attributes)
        }
    }
}
