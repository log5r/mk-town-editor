import AppKit
import Foundation

enum MarkdownRichClipboardError: LocalizedError {
    case writeFailed

    var errorDescription: String? { String(localized: "クリップボードへ書き込めませんでした。") }
}

@MainActor
enum MarkdownRichClipboard {
    static func payload(for markdown: String, documentURL: URL?,
                        dialect: MarkdownDialect = .extended) throws -> Payload {
        let html = MarkdownHTMLExporter.render(markdown, documentURL: documentURL,
                                               dialect: dialect)
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

    /// Renders `markdown` and writes it to `pasteboard`. Rendering can take seconds, and a copy
    /// the user makes meanwhile must win: the result is written only while the pasteboard's
    /// change count still equals `startingChangeCount` (read when the copy was requested;
    /// defaults to now). Otherwise this throws `CancellationError` and leaves the newer contents.
    static func copyAsync(_ markdown: String, documentURL: URL?, to pasteboard: NSPasteboard,
                          dialect: MarkdownDialect = .extended,
                          startingChangeCount: Int? = nil) async throws {
        let expectedChangeCount = startingChangeCount ?? pasteboard.changeCount
        let html = try await MarkdownHTMLExporter.renderAsync(markdown, documentURL: documentURL, dialect: dialect, images: .embedBase64)
        let rendered = AttributedTransfer(try await DocumentWork.loadHTML(html))
        let rtf = try await DocumentWork.perform {
            try rendered.value.data(from: NSRange(location: 0, length: rendered.value.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
        try Task.checkCancellation()
        var plain = rendered.value.string
        if plain.hasSuffix("\n") { plain.removeLast() }
        guard pasteboard.changeCount == expectedChangeCount else { throw CancellationError() }
        try write(Payload(html: html, rtf: rtf, plainText: plain), to: pasteboard)
    }

    static func copy(_ markdown: String, documentURL: URL?, to pasteboard: NSPasteboard,
                     dialect: MarkdownDialect = .extended) throws {
        let data = try payload(for: markdown, documentURL: documentURL, dialect: dialect)
        try write(data, to: pasteboard)
    }

    private static func write(_ data: Payload, to pasteboard: NSPasteboard) throws {
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
