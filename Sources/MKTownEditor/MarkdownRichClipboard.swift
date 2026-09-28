import AppKit
import Foundation

enum MarkdownRichClipboardError: LocalizedError {
    case writeFailed

    var errorDescription: String? { "クリップボードへ書き込めませんでした。" }
}

@MainActor
enum MarkdownRichClipboard {
    static func payload(for markdown: String, documentURL: URL?) throws -> Payload {
        let html = MarkdownHTMLExporter.render(markdown, documentURL: documentURL)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let rendered = try NSAttributedString(data: Data(html.utf8), options: options,
                                              documentAttributes: nil)
        let rtf = try rendered.data(from: NSRange(location: 0, length: rendered.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        var plainText = rendered.string
        if plainText.hasSuffix("\n") { plainText.removeLast() }
        return Payload(html: html, rtf: rtf, plainText: plainText)
    }

    static func copy(_ markdown: String, documentURL: URL?, to pasteboard: NSPasteboard) throws {
        let data = try payload(for: markdown, documentURL: documentURL)
        pasteboard.declareTypes([.html, .rtf, .string], owner: nil)
        guard pasteboard.setString(data.html, forType: .html),
              pasteboard.setData(data.rtf, forType: .rtf),
              pasteboard.setString(data.plainText, forType: .string) else {
            throw MarkdownRichClipboardError.writeFailed
        }
    }

    struct Payload {
        let html: String
        let rtf: Data
        let plainText: String
    }
}
