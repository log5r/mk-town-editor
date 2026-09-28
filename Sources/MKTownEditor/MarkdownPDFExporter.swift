import AppKit
import Foundation

enum MarkdownPDFExportError: LocalizedError {
    case printingFailed
    case emptyOutput
    case invalidMargins

    var errorDescription: String? {
        switch self {
        case .printingFailed: String(localized: "PDFの作成に失敗しました。")
        case .emptyOutput: String(localized: "作成したPDFを読み取れません。")
        case .invalidMargins: String(localized: "余白が用紙サイズに対して大きすぎます。")
        }
    }
}

struct MarkdownPrintSettings {
    var topMargin: Double = 48
    var bottomMargin: Double = 48
    var leftMargin: Double = 48
    var rightMargin: Double = 48
    var header = false
    var footer = false

    func isValid(for paperSize: NSSize) -> Bool {
        [topMargin, bottomMargin, leftMargin, rightMargin].allSatisfy { $0.isFinite && $0 >= 0 }
            && paperSize.width - leftMargin - rightMargin >= 100
            && paperSize.height - topMargin - bottomMargin >= 100
    }

    func apply(to info: NSPrintInfo) throws {
        guard isValid(for: info.paperSize) else { throw MarkdownPDFExportError.invalidMargins }
        info.topMargin = topMargin
        info.bottomMargin = bottomMargin
        info.leftMargin = leftMargin
        info.rightMargin = rightMargin
        info.dictionary()[NSPrintInfo.AttributeKey(rawValue: "NSPrintHeaderAndFooter")] = header || footer
    }
}

@MainActor
enum MarkdownPDFExporter {
    static func printInfo(destination: URL, preset: MarkdownExportPreset = .standard) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.leftMargin = CGFloat(preset.margin)
        info.rightMargin = CGFloat(preset.margin)
        info.topMargin = CGFloat(preset.margin)
        info.bottomMargin = CGFloat(preset.margin)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        return info
    }

    static func export(_ markdown: String, documentURL: URL?, to destination: URL,
                       preset: MarkdownExportPreset = .standard,
                       dialect: MarkdownDialect = .extended) throws {
        let info = printInfo(destination: destination, preset: preset)
        let textView = try printableView(markdown, documentURL: documentURL, printInfo: info,
                                         preset: preset, dialect: dialect)
        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw MarkdownPDFExportError.printingFailed }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
            throw MarkdownPDFExportError.emptyOutput
        }
    }

    static func printableView(_ markdown: String, documentURL: URL?, printInfo info: NSPrintInfo,
                              title: String = "", header: Bool = false, footer: Bool = false,
                              preset: MarkdownExportPreset = .standard,
                              dialect: MarkdownDialect = .extended) throws -> NSTextView {
        let preferredWidth = CGFloat(preset.bodyWidth) * 0.75
        let width = min(info.paperSize.width - info.leftMargin - info.rightMargin, preferredWidth)
        let height = info.paperSize.height - info.topMargin - info.bottomMargin
        guard width >= 100, height >= 100 else { throw MarkdownPDFExportError.invalidMargins }
        let html = MarkdownHTMLExporter.render(markdown, documentURL: documentURL,
                                               preset: preset, printLayout: true, dialect: dialect)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let attributed = NSMutableAttributedString(attributedString: try NSAttributedString(
            data: Data(html.utf8), options: options, documentAttributes: nil
        ))
        let textView = PDFTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.printableHeight = height
        textView.preferredWidth = preferredWidth
        textView.headerTitle = title
        textView.showsHeader = header
        textView.showsFooter = footer
        let markerRange = (attributed.string as NSString).range(of: MarkdownHTMLExporter.coverBreakMarker)
        if markerRange.location != NSNotFound {
            attributed.deleteCharacters(in: markerRange)
            textView.coverBreakCharacter = markerRange.location
        }
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
        return textView
    }
}

private final class PDFTextView: NSTextView {
    var printableHeight: CGFloat = 740
    var preferredWidth: CGFloat = 600
    var headerTitle = ""
    var showsHeader = false
    var showsFooter = false
    var coverBreakCharacter: Int?
    private var pageRects: [NSRect] = []

    override var pageHeader: NSAttributedString {
        NSAttributedString(string: showsHeader ? headerTitle : "")
    }

    override var pageFooter: NSAttributedString {
        guard showsFooter, let operation = NSPrintOperation.current else {
            return NSAttributedString(string: "")
        }
        return NSAttributedString(string: "\(operation.currentPage) / \(operation.pageRange.length)")
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        guard let layoutManager, let textStorage else { return false }
        if let info = NSPrintOperation.current?.printInfo {
            let width = max(100, min(info.paperSize.width - info.leftMargin - info.rightMargin,
                                     preferredWidth))
            printableHeight = max(100, info.paperSize.height - info.topMargin - info.bottomMargin)
            if abs(bounds.width - width) > 0.5 {
                frame.size.width = width
                textContainer?.containerSize.width = width
                layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0,
                                                                           length: textStorage.length),
                                               actualCharacterRange: nil)
            }
            if let textContainer {
                layoutManager.ensureLayout(for: textContainer)
                frame.size.height = max(100, ceil(layoutManager.usedRect(for: textContainer).height))
            }
        }
        pageRects = []
        var start: CGFloat = 0
        var glyph = 0
        var paragraphLocation = NSNotFound
        var paragraphStart: CGFloat = 0
        var insertedCoverBreak = false
        let text = textStorage.string as NSString
        while glyph < layoutManager.numberOfGlyphs {
            var effective = NSRange()
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            let characters = layoutManager.characterRange(forGlyphRange: effective,
                                                          actualGlyphRange: nil)
            if !insertedCoverBreak, let coverBreakCharacter,
               characters.location >= coverBreakCharacter, line.minY > start {
                pageRects.append(NSRect(x: 0, y: start, width: bounds.width,
                                        height: line.minY - start))
                start = line.minY
                insertedCoverBreak = true
            }
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
