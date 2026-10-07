import AppKit

struct MarkdownLineNumberIndex {
    let starts: [Int]

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
    static func labels(in textView: NSTextView, visibleRect: NSRect) -> [MarkdownLineNumberLabel] {
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let source = textView.editorSource as NSString
        let index = MarkdownLineNumberIndex(textView.editorSource)
        if source.length == 0 {
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

        if index.starts.last == source.length {
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

    init(scrollView: NSScrollView, editor: NSTextView) {
        self.editor = editor
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = editor
        setAccessibilityLabel("行番号")
        refresh()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        guard let editor else { return }
        let digits = String(MarkdownLineNumberIndex(editor.editorSource).starts.count).count
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
        let lineStarts = MarkdownLineNumberIndex(editor.editorSource).starts
        for label in MarkdownLineNumberLayout.labels(in: editor, visibleRect: editor.visibleRect) {
            let point = convert(label.origin, from: editor)
            if let foldingEditor = editor as? EditorTextView,
               label.number <= lineStarts.count,
               foldingEditor.foldedHeaderLocations.contains(lineStarts[label.number - 1]) {
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
