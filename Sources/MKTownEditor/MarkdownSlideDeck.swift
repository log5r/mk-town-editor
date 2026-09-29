import AppKit
import PDFKit

struct MarkdownSlideDeck: Sendable {
    let slides: [String]

    init(_ markdown: String, dialect: MarkdownDialect = .extended) {
        // Segment with the basic block parser so a leading slide rule is never hidden as YAML.
        let analysis = MarkdownAnalysis(markdown, dialect: .basic)
        let source = markdown as NSString
        let frontMatter = MarkdownFrontMatter(source: markdown).flatMap { matter -> MarkdownFrontMatter? in
            let first = matter.content.components(separatedBy: .newlines)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            return first.range(of: #"^[A-Za-z_][A-Za-z0-9_-]*[ \t]*:"#,
                               options: .regularExpression) == nil ? nil : matter
        }
        var start = frontMatter.map { NSMaxRange($0.sourceRange) } ?? 0
        var pages: [String] = []
        for block in analysis.rootBlocks where block.kind == .horizontalRule &&
                                             block.sourceRange.location >= start {
            let end = block.sourceRange.location
            if end >= start {
                let content = source.substring(with: NSRange(location: start, length: end - start))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { pages.append(content) }
            }
            start = NSMaxRange(block.sourceRange)
        }
        let final = source.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty { pages.append(final) }
        slides = pages.isEmpty ? [""] : pages
    }
}

enum MarkdownSlidePDFError: LocalizedError {
    case invalidPage
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidPage: String(localized: "スライドのPDFページを作成できません。")
        case .writeFailed: String(localized: "スライドPDFを保存できません。")
        }
    }
}

@MainActor
enum MarkdownSlidePDFExporter {
    static func export(_ deck: MarkdownSlideDeck, documentURL: URL?, to destination: URL,
                       dialect: MarkdownDialect = .extended) throws {
        let output = PDFDocument()
        for slide in deck.slides {
            let html = MarkdownHTMLExporter.render(slide, documentURL: documentURL, dialect: dialect)
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ]
            let attributed = try NSAttributedString(data: Data(html.utf8), options: options,
                                                     documentAttributes: nil)
            let pageView = MarkdownSlidePDFPage(frame: NSRect(x: 0, y: 0, width: 842, height: 595),
                                                content: attributed)
            guard let page = PDFDocument(data: pageView.dataWithPDF(inside: pageView.bounds))?.page(at: 0) else {
                throw MarkdownSlidePDFError.invalidPage
            }
            output.insert(page, at: output.pageCount)
        }
        guard output.write(to: destination) else { throw MarkdownSlidePDFError.writeFailed }
    }
}

private final class MarkdownSlidePDFPage: NSView {
    private let content: NSAttributedString

    init(frame: NSRect, content: NSAttributedString) {
        self.content = content
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        let inset: CGFloat = 48
        let width = bounds.width - inset * 2
        let height = bounds.height - inset * 2
        let measured = content.boundingRect(with: NSSize(width: width, height: 100_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let scale = min(1, height / max(1, measured.height))
        guard let graphics = NSGraphicsContext.current else { return }
        graphics.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: inset, yBy: inset)
        transform.scale(by: scale)
        transform.concat()
        content.draw(with: NSRect(x: 0, y: 0, width: width / scale,
                                  height: height / scale),
                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        graphics.restoreGraphicsState()
    }
}
