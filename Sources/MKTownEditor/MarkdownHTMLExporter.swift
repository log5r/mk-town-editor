import AppKit
import Foundation

@MainActor
enum MarkdownHTMLExporter {
    static let coverBreakMarker = "\u{E000}"

    static func render(_ markdown: String, documentURL: URL? = nil,
                       preset: MarkdownExportPreset = .standard, printLayout: Bool = false,
                       dialect: MarkdownDialect = .extended) -> String {
        let analysis = MarkdownAnalysis(markdown, dialect: dialect)
        let anchors = Dictionary(uniqueKeysWithValues: MarkdownHeadingIndex(analysis: analysis).anchors.map {
            ($0.entry.id, $0.slug)
        })
        var body = sequence(analysis.rootBlocks, analysis: analysis,
                            context: DocumentContext(fileURL: documentURL), anchors: anchors)
        for note in analysis.footnotes.entries {
            let token = "<sup><a href=\"#fn-\(note.number)\""
            if let range = body.range(of: token) {
                body.replaceSubrange(range, with: "<sup><a id=\"fnref-\(note.number)\" href=\"#fn-\(note.number)\"")
            }
        }
        if !analysis.footnotes.entries.isEmpty {
            body += "<section class=\"footnotes\"><h2>脚注</h2><ol>"
            for note in analysis.footnotes.entries {
                body += "<li id=\"fn-\(note.number)\">" +
                    inline(note.content, analysis: analysis,
                           context: DocumentContext(fileURL: documentURL)) +
                    " <a href=\"#fnref-\(note.number)\" aria-label=\"本文に戻る\">↩</a></li>"
            }
            body += "</ol></section>"
        }
        let title = MarkdownOutline.entries(in: analysis).first.map { visibleText($0.title) }
            ?? documentURL?.deletingPathExtension().lastPathComponent ?? "無題"
        let cover = preset.cover
            ? "<section class=\"cover\"><h1>\(escape(title))</h1></section>\n" +
                (printLayout ? "<p>\(coverBreakMarker)</p>\n" : "") : ""
        let tableOfContents = preset.tableOfContents
            ? "<nav aria-label=\"目次\"><h2>目次</h2><ol>" +
                MarkdownHeadingIndex(analysis: analysis).anchors.map {
                    "<li><a href=\"#\(escape($0.slug))\">\(escape(visibleText($0.entry.title)))</a></li>"
                }.joined() + "</ol></nav>\n" : ""
        return """
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; }
        body { box-sizing: border-box; max-width: \(preset.bodyWidth)px; margin: 0 auto; padding: 32px 24px;
               font: \(preset.fontSize)px/1.65 \(preset.font.cssFamily); overflow-wrap: anywhere; }
        pre { overflow-x: auto; padding: 16px; border-radius: 8px; background: color-mix(in srgb, currentColor 8%, transparent); }
        code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
        img { max-width: 100%; height: auto; }
        figure { margin: 1em 0; }
        figcaption { color: color-mix(in srgb, currentColor 70%, transparent); font-size: 0.85em; }
        table { border-collapse: collapse; display: block; overflow-x: auto; }
        th, td { border: 1px solid #8888; padding: 5px 10px; }
        blockquote { border-left: 3px solid #8888; margin-left: 0; padding-left: 16px; }
        .callout { border-left: 3px solid currentColor; background: color-mix(in srgb, currentColor 6%, transparent);
                   padding: 12px 16px; margin: 1em 0; border-radius: 6px; }
        .cover { min-height: 70vh; display: flex; align-items: center; justify-content: center; text-align: center; }
        nav { margin-bottom: 2em; }
        sup { font-size: 0.75em; }
        .footnotes { margin-top: 2em; border-top: 1px solid #8888; font-size: 0.9em; }
        @page { margin: \(preset.margin)pt; }
        @media print {
          body { max-width: none; margin: 0; padding: 0; }
          .cover { break-after: page; }
          h1, h2, h3, h4, h5, h6 { break-after: avoid-page; }
          pre, blockquote, img, tr { break-inside: avoid-page; }
          table { display: table; overflow: visible; max-width: 100%; }
        }
        </style>
        </head>
        <body>
        \(cover)\(tableOfContents)
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
            if context.markdownDialect == .extended,
               let formula = MarkdownMath.displayFormula(block.content) {
                return "<div class=\"math-block\">\(MarkdownMathRenderer.htmlImage(formula, fontSize: 21) ?? escape(formula.source))</div>\n"
            }
            let content = MarkdownRenderer.paragraphContent(block)
            let layout = MarkdownImageLayout.parse(
                MarkdownRenderer.resolveReferences(in: content, using: analysis.references))
            let rendered = inline(content, analysis: analysis, context: context)
            if let caption = layout.standaloneCaption {
                return "<figure>\(rendered)<figcaption>\(escape(caption))</figcaption></figure>\n"
            }
            return "<p>\(rendered)</p>\n"
        case .quote:
            let content = sequence(analysis.children(of: block), analysis: analysis,
                                   context: context, anchors: anchors)
            if let callout = block.calloutKind {
                return "<aside class=\"callout\" aria-label=\"\(escape(callout.title))\"><strong>\(escape(callout.title))</strong>\n\(content)</aside>\n"
            }
            return "<blockquote>\n\(content)</blockquote>\n"
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
        let layout = MarkdownImageLayout.parse(
            MarkdownRenderer.resolveReferences(
                in: MarkdownSafeHTML.previewMarkdown(markdown), using: analysis.references))
        let math: (text: String, formulas: [(String, MarkdownMath.Formula)]) = context.markdownDialect == .extended
            ? MarkdownMath.placeholders(in: layout.markdown) : (layout.markdown, [])
        let resolved = math.text
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: resolved, options: options) else {
            return escape(resolved)
        }
        let value = NSMutableAttributedString(parsed)
        MarkdownAutolink.apply(to: value)
        let source = value.string as NSString
        var html = ""
        var imageIndex = 0
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            let text = source.substring(with: range)
            if let image = attributes[.imageURL] as? URL {
                let alt = (attributes[.alternateDescription] as? String) ?? text
                let width = imageIndex < layout.widths.count ? layout.widths[imageIndex] : nil
                imageIndex += 1
                if let url = imageSource(image, context: context) {
                    let widthAttribute = width.map { " width=\"\(Int($0))\"" } ?? ""
                    html += "<img src=\"\(escape(url))\" alt=\"\(escape(alt))\"\(widthAttribute)>"
                } else {
                    html += escape(alt)
                }
                return
            }
            let intent = (attributes[.inlinePresentationIntent] as? InlinePresentationIntent)
                ?? (attributes[.inlinePresentationIntent] as? NSNumber)
                    .map { InlinePresentationIntent(rawValue: $0.uintValue) }
            var run = (intent?.contains(.code) == true || attributes[.link] != nil ? escape(text)
                : footnoteHTML(text, analysis: analysis))
                .replacingOccurrences(of: "\n", with: "<br>")
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
        for (token, formula) in math.formulas {
            html = html.replacingOccurrences(of: token,
                with: MarkdownMathRenderer.htmlImage(formula) ?? escape(formula.source))
        }
        return html
    }

    private static func footnoteHTML(_ text: String, analysis: MarkdownAnalysis) -> String {
        let source = text as NSString
        let expression = try! NSRegularExpression(pattern: #"\[\^([^\]\n]+)\]"#)
        var output = ""
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += escape(source.substring(with: NSRange(location: cursor,
                length: match.range.location - cursor)))
            let id = source.substring(with: match.range(at: 1))
            if let note = analysis.footnotes.entry(for: id) {
                output += "<sup><a href=\"#fn-\(note.number)\">\(note.number)</a></sup>"
            } else {
                output += escape(source.substring(with: match.range))
            }
            cursor = NSMaxRange(match.range)
        }
        output += escape(source.substring(from: cursor))
        return output
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

    private static func visibleText(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options))
            .map { String($0.characters) } ?? markdown
    }
}
