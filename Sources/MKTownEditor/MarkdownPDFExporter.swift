import AppKit
import Foundation

enum MarkdownPDFExportError: LocalizedError {
    case printingFailed
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .printingFailed: "PDFの作成に失敗しました。"
        case .emptyOutput: "作成したPDFを読み取れません。"
        }
    }
}

@MainActor
enum MarkdownPDFExporter {
    static func printInfo(destination: URL) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.leftMargin = 48
        info.rightMargin = 48
        info.topMargin = 48
        info.bottomMargin = 48
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        return info
    }

    static func export(_ markdown: String, documentURL: URL?, to destination: URL) throws {
        let html = MarkdownHTMLExporter.render(markdown, documentURL: documentURL)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let attributed = try NSAttributedString(data: Data(html.utf8), options: options,
                                                 documentAttributes: nil)
        let info = printInfo(destination: destination)
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let textView = PDFTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.printableHeight = info.paperSize.height - info.topMargin - info.bottomMargin
        textView.isRichText = true
        textView.isEditable = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attributed)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            textView.frame.size.height = max(100, ceil(layoutManager.usedRect(for: container).height))
        }
        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw MarkdownPDFExportError.printingFailed }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
            throw MarkdownPDFExportError.emptyOutput
        }
    }
}

private final class PDFTextView: NSTextView {
    var printableHeight: CGFloat = 740
    private var pageRects: [NSRect] = []

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        guard let layoutManager, let textStorage else { return false }
        pageRects = []
        var start: CGFloat = 0
        var glyph = 0
        var paragraphLocation = NSNotFound
        var paragraphStart: CGFloat = 0
        let text = textStorage.string as NSString
        while glyph < layoutManager.numberOfGlyphs {
            var effective = NSRange()
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            let characters = layoutManager.characterRange(forGlyphRange: effective,
                                                          actualGlyphRange: nil)
            let paragraph = text.paragraphRange(for: characters)
            if paragraph.location != paragraphLocation {
                paragraphLocation = paragraph.location
                paragraphStart = line.minY
            }
            if line.maxY > start + printableHeight && line.minY > start {
                // Keep a short paragraph together when it crosses a page boundary.
                let nextStart = paragraphStart > start ? paragraphStart : line.minY
                pageRects.append(NSRect(x: 0, y: start, width: bounds.width,
                                        height: nextStart - start))
                start = nextStart
            }
            let nextGlyph = NSMaxRange(effective)
            guard nextGlyph > glyph else { break }
            glyph = nextGlyph
        }
        pageRects.append(NSRect(x: 0, y: start, width: bounds.width,
                                height: max(1, bounds.height - start)))
        range.pointee = NSRange(location: 1, length: pageRects.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        guard page > 0, page <= pageRects.count else { return .zero }
        return pageRects[page - 1]
    }
}
