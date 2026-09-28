import AppKit
import Foundation

@MainActor
enum MarkdownHTMLExporter {
    static func render(_ markdown: String, documentURL: URL? = nil) -> String {
        let analysis = MarkdownAnalysis(markdown)
        let anchors = Dictionary(uniqueKeysWithValues: MarkdownHeadingIndex(analysis: analysis).anchors.map {
            ($0.entry.id, $0.slug)
        })
        let body = sequence(analysis.rootBlocks, analysis: analysis,
                            context: DocumentContext(fileURL: documentURL), anchors: anchors)
        return """
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { box-sizing: border-box; max-width: 800px; margin: 0 auto; padding: 32px 24px;
               font: 16px/1.65 -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
        pre { overflow-x: auto; padding: 16px; border-radius: 8px; background: color-mix(in srgb, currentColor 8%, transparent); }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        img { max-width: 100%; height: auto; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid #8888; padding: 5px 10px; }
        blockquote { border-left: 3px solid #8888; margin-left: 0; padding-left: 16px; }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    private static func sequence(_ blocks: [MarkdownBlock], analysis: MarkdownAnalysis,
                                 context: DocumentContext, anchors: [Int: String]) -> String {
        var html = ""
        var index = 0
        while index < blocks.count {
            let block = blocks[index]
            let listTag: String?
            switch block.kind {
            case .unorderedList: listTag = "ul"
            case .orderedList: listTag = "ol"
            default: listTag = nil
            }
            if let listTag {
                let start = index
                while index < blocks.count {
                    let matches: Bool
                    switch blocks[index].kind {
                    case .unorderedList: matches = listTag == "ul"
                    case .orderedList: matches = listTag == "ol"
                    default: matches = false
                    }
                    if !matches { break }
                    index += 1
                }
                let startAttribute: String
                if case let .orderedList(number) = block.kind, number != 1 {
                    startAttribute = " start=\"\(number)\""
                } else {
                    startAttribute = ""
                }
                html += "<\(listTag)\(startAttribute)>\n"
                for item in blocks[start..<index] {
                    let task = item.task
                    let label = task?.content ?? MarkdownRenderer.paragraphContent(item)
                    let checkbox = task.map {
                        "<input type=\"checkbox\" disabled\($0.isChecked ? " checked" : "")> "
                    } ?? ""
                    let children = sequence(analysis.children(of: item), analysis: analysis,
                                            context: context, anchors: anchors)
                    html += "<li>\(checkbox)\(inline(label, analysis: analysis, context: context))\(children)</li>\n"
                }
                html += "</\(listTag)>\n"
                continue
            }
            html += element(block, analysis: analysis, context: context, anchors: anchors)
            index += 1
        }
        return html
    }

    private static func element(_ block: MarkdownBlock, analysis: MarkdownAnalysis,
                                context: DocumentContext, anchors: [Int: String]) -> String {
        switch block.kind {
        case .blank: return ""
        case let .heading(level):
            let anchor = escape(anchors[block.id] ?? "section")
            return "<h\(level) id=\"\(anchor)\">\(inline(block.content, analysis: analysis, context: context))</h\(level)>\n"
        case .paragraph:
            return "<p>\(inline(MarkdownRenderer.paragraphContent(block), analysis: analysis, context: context))</p>\n"
        case .quote:
            return "<blockquote>\n\(sequence(analysis.children(of: block), analysis: analysis, context: context, anchors: anchors))</blockquote>\n"
        case .codeBlock:
            let language = block.codeLanguage.map { " class=\"language-\(escape($0))\"" } ?? ""
            return "<pre><code\(language)>\(escape(block.content))</code></pre>\n"
        case .horizontalRule: return "<hr>\n"
        case .table:
            guard let table = block.table else { return "" }
            func cell(_ text: String, column: Int, tag: String) -> String {
                let alignment = switch table.alignments[column] {
                case .leading: "left"
                case .center: "center"
                case .trailing: "right"
                }
                return "<\(tag) style=\"text-align:\(alignment)\">\(inline(text, analysis: analysis, context: context))</\(tag)>"
            }
            let header = table.header.enumerated().map { cell($0.element, column: $0.offset, tag: "th") }.joined()
            let rows = table.rows.map { row in
                "<tr>" + row.enumerated().map { cell($0.element, column: $0.offset, tag: "td") }.joined() + "</tr>\n"
            }.joined()
            return "<table><thead><tr>\(header)</tr></thead><tbody>\(rows)</tbody></table>\n"
        case .unorderedList, .orderedList:
            return ""
        }
    }

    private static func inline(_ markdown: String, analysis: MarkdownAnalysis,
                               context: DocumentContext) -> String {
        let resolved = MarkdownRenderer.resolveReferences(in: markdown, using: analysis.references)
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: resolved, options: options) else {
            return escape(resolved)
        }
        let value = NSAttributedString(parsed)
        let source = value.string as NSString
        var html = ""
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            let text = source.substring(with: range)
            if let image = attributes[.imageURL] as? URL {
                let alt = (attributes[.alternateDescription] as? String) ?? text
                if let url = imageSource(image, context: context) {
                    html += "<img src=\"\(escape(url))\" alt=\"\(escape(alt))\">"
                } else {
                    html += escape(alt)
                }
                return
            }
            var run = escape(text).replacingOccurrences(of: "\n", with: "<br>")
            let intent = (attributes[.inlinePresentationIntent] as? InlinePresentationIntent)
                ?? (attributes[.inlinePresentationIntent] as? NSNumber)
                    .map { InlinePresentationIntent(rawValue: $0.uintValue) }
            if intent?.contains(.code) == true { run = "<code>\(run)</code>" }
            if intent?.contains(.stronglyEmphasized) == true { run = "<strong>\(run)</strong>" }
            if intent?.contains(.emphasized) == true { run = "<em>\(run)</em>" }
            if intent?.contains(.strikethrough) == true { run = "<del>\(run)</del>" }
            if let link = attributes[.link],
               let destination = safeLink(link) {
                run = "<a href=\"\(escape(destination))\">\(run)</a>"
            }
            html += run
        }
        return html
    }

    private static func imageSource(_ url: URL, context: DocumentContext) -> String? {
        if url.scheme == "http" || url.scheme == "https" { return url.absoluteString }
        guard url.scheme == nil,
              let fileURL = context.resolveLocalResource(url.relativeString),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        let mime: String
        switch fileURL.pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        default: return nil
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    private static func safeLink(_ value: Any) -> String? {
        let text = (value as? URL)?.relativeString ?? value as? String
        guard let text, let url = URL(string: text),
              url.scheme == nil || ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return text
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
