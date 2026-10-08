import AppKit
import Foundation
import WebKit

enum MarkdownHTMLExporter {
    static let coverBreakMarker = "\u{E000}"

    /// How local files referenced by images, media and links are written.
    /// Map keys and resolver arguments are symlink-resolved, standardized file URLs;
    /// values are written as-is into `src`/`href`, so they must already be valid URL text.
    enum ImageSource: Sendable {
        /// Embed local images as base64 `data:` URIs so the HTML stands alone.
        case embedBase64
        /// Reference mapped files instead of embedding them. Unmapped images fall back
        /// to their alt text and unmapped links keep their original destination.
        case relative(pathMap: [URL: String])
        /// Like `relative`, but asks for each file while rendering (e.g. to collect uploads).
        case resolver(@Sendable (URL) -> String?)

        func destination(for fileURL: URL) -> String? {
            let key = fileURL.resolvingSymlinksInPath().standardizedFileURL
            switch self {
            case .embedBase64: return nil
            case let .relative(pathMap): return pathMap[key]
            case let .resolver(resolve): return resolve(key)
            }
        }
    }

    @TaskLocal private static var activeImages: ImageSource = .embedBase64
    @TaskLocal private static var activeOutputURL: URL?
    @TaskLocal private static var mathImages: [String: String] = [:]

    /// `outputURL` is where the HTML will be saved. With `.embedBase64`, local media links are
    /// written relative to it; without it they stay absolute `file:` URLs for local use.
    @MainActor
    static func render(_ markdown: String, documentURL: URL? = nil,
                       preset: MarkdownExportPreset = .standard, printLayout: Bool = false,
                       dialect: MarkdownDialect = .extended, images: ImageSource = .embedBase64,
                       outputURL: URL? = nil) -> String {
        let analysis = MarkdownAnalysis(markdown, dialect: dialect)
        let resources = formulas(in: analysis).reduce(into: [String: String]()) { values, item in
            values[item.key] = MarkdownMathRenderer.htmlImage(item.formula, fontSize: item.size)
        }
        return $mathImages.withValue(resources) {
            $activeImages.withValue(images) {
                $activeOutputURL.withValue(outputURL) {
                    renderPrepared(analysis, documentURL: documentURL, preset: preset, printLayout: printLayout, dialect: dialect)
                }
            }
        }
    }

    @MainActor
    static func renderAsync(_ markdown: String, documentURL: URL? = nil,
                            preset: MarkdownExportPreset = .standard, printLayout: Bool = false,
                            dialect: MarkdownDialect = .extended, images: ImageSource = .embedBase64,
                            outputURL: URL? = nil) async throws -> String {
        let analysis = try await DocumentWork.perform { MarkdownAnalysis(markdown, dialect: dialect) }
        let items = try await DocumentWork.perform { formulas(in: analysis) }
        var resources: [String: String] = [:]
        for item in items {
            try Task.checkCancellation()
            resources[item.key] = MarkdownMathRenderer.htmlImage(item.formula, fontSize: item.size)
            await Task.yield()
        }
        let prepared = resources
        return try await DocumentWork.perform {
            $mathImages.withValue(prepared) {
                $activeImages.withValue(images) {
                    $activeOutputURL.withValue(outputURL) {
                        renderPrepared(analysis, documentURL: documentURL, preset: preset, printLayout: printLayout, dialect: dialect)
                    }
                }
            }
        }
    }

    private struct MathImage: Sendable {
        let formula: MarkdownMath.Formula
        let size: CGFloat
        var key: String { "\(size):\(formula.latex)" }
    }

    private static func formulas(in analysis: MarkdownAnalysis) -> [MathImage] {
        guard analysis.dialect == .extended else { return [] }
        var result: [String: MathImage] = [:]
        for block in analysis.blocks where block.kind != .codeBlock {
            var texts = [block.content]
            if let table = block.table { texts += table.header + table.rows.flatMap { $0 } }
            for text in texts {
                if let formula = MarkdownMath.displayFormula(text) {
                    let item = MathImage(formula: formula, size: 21); result[item.key] = item
                }
                for (_, formula) in MarkdownMath.placeholders(in: text).formulas {
                    let item = MathImage(formula: formula, size: 16); result[item.key] = item
                }
            }
        }
        for note in analysis.footnotes.entries {
            for (_, formula) in MarkdownMath.placeholders(in: note.content).formulas {
                let item = MathImage(formula: formula, size: 16); result[item.key] = item
            }
        }
        return Array(result.values)
    }

    private static func mathImage(_ formula: MarkdownMath.Formula, fontSize: CGFloat = 16) -> String? {
        mathImages["\(fontSize):\(formula.latex)"]
    }

    private static func renderPrepared(_ analysis: MarkdownAnalysis, documentURL: URL?,
                                      preset: MarkdownExportPreset, printLayout: Bool,
                                      dialect: MarkdownDialect) -> String {
        let anchors = Dictionary(uniqueKeysWithValues: MarkdownHeadingIndex(analysis: analysis).anchors.map {
            ($0.entry.id, $0.slug)
        })
        var context = DocumentContext(fileURL: documentURL, markdownDialect: dialect)
        context.crossReferences = analysis.crossReferences
        // 参考文献は書き出し1回につき1度だけ解決し、段落ごとに読み直さない。
        context.citationCatalog = dialect == .extended && analysis.containsCitationSyntax
            ? MarkdownCitationCatalog.load(documentURL: documentURL) ?? .empty : .empty
        var body = sequence(analysis.rootBlocks, analysis: analysis,
                            context: context, anchors: anchors)
        for note in analysis.footnotes.entries {
            let token = "<sup><a href=\"#fn-\(note.number)\""
            if let range = body.range(of: token) {
                body.replaceSubrange(range, with: "<sup><a id=\"fnref-\(note.number)\" href=\"#fn-\(note.number)\"")
            }
        }
        if !analysis.footnotes.entries.isEmpty {
            body += "<section class=\"footnotes\"><h2>\(escape(String(localized: "脚注")))</h2><ol>"
            for note in analysis.footnotes.entries {
                body += "<li id=\"fn-\(note.number)\">" +
                    inline(note.content, analysis: analysis,
                           context: context) +
                    " <a href=\"#fnref-\(note.number)\" aria-label=\"\(escape(String(localized: "本文に戻る")))\">↩</a></li>"
            }
            body += "</ol></section>"
        }
        if dialect == .extended,
           let catalog = context.citationCatalog,
           catalog.hasCitation(in: analysis) {
            body += "<section class=\"bibliography\"><h2>\(escape(String(localized: "参考文献")))</h2><ol>"
            for entry in catalog.entries {
                body += "<li>\(escape(entry.bibliographyText))</li>"
            }
            body += "</ol></section>"
        }
        let title = MarkdownOutline.entries(in: analysis).first.map { visibleText($0.title) }
            ?? documentURL?.deletingPathExtension().lastPathComponent ?? String(localized: "無題")
        let cover = preset.cover
            ? "<section class=\"cover\"><h1>\(escape(title))</h1></section>\n" +
                (printLayout ? "<p>\(coverBreakMarker)</p>\n" : "") : ""
        let tableOfContents = preset.tableOfContents
            ? "<nav aria-label=\"\(escape(String(localized: "目次")))\"><h2>\(escape(String(localized: "目次")))</h2><ol>" +
                MarkdownHeadingIndex(analysis: analysis).anchors.map {
                    "<li><a href=\"#\(escape($0.slug))\">\(escape(visibleText($0.entry.title)))</a></li>"
                }.joined() + "</ol></nav>\n" : ""
        return """
        <!doctype html>
        <html lang="\(escape(documentLanguage(analysis)))">
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
        dl { margin: 1em 0; }
        dt { font-weight: 600; margin-top: 0.6em; }
        dd { margin-left: 1.5em; }
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
            if Task<Never, Never>.isCancelled { break }
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
            if analysis.crossReferences.markerBlockIDs.contains(block.id) { return "" }
            if let media = MarkdownMedia(block, dialect: context.markdownDialect) {
                let label = escape(media.label)
                if let url = media.localURL(in: context) {
                    guard let destination = mediaDestination(url) else { return "<p>\(label)</p>\n" }
                    return "<p><a href=\"\(escape(destination))\">\(label)</a></p>\n"
                }
                return "<p>\(escape(String(localized: "\(media.label)（再生不可）")))</p>\n"
            }
            if let definitions = MarkdownDefinitionList(block, dialect: context.markdownDialect) {
                let entries = definitions.entries.map { entry in
                    "<dt>\(inline(entry.term, analysis: analysis, context: context))</dt>" +
                        entry.definitions.map {
                            "<dd>\(inline($0, analysis: analysis, context: context))</dd>"
                        }.joined()
                }.joined()
                return "<dl>\(entries)</dl>\n"
            }
            let target = analysis.crossReferences.target(forBlockID: block.id)
            if context.markdownDialect == .extended,
               let formula = MarkdownMath.displayFormula(block.content) {
                let id = target.map { " id=\"\(escape($0.key))\"" } ?? ""
                let number = target.map { "<span class=\"number\">\(escape($0.label))</span>" } ?? ""
                return "<div class=\"math-block\"\(id)>\(mathImage(formula, fontSize: 21) ?? escape(formula.source))\(number)</div>\n"
            }
            let content = MarkdownRenderer.paragraphContent(block)
            let layout = MarkdownImageLayout.parse(
                MarkdownRenderer.resolveReferences(in: content, using: analysis.references))
            let rendered = inline(content, analysis: analysis, context: context)
            if let caption = layout.standaloneCaption {
                let id = target.map { " id=\"\(escape($0.key))\"" } ?? ""
                let number = target.map { "\(escape($0.label)) " } ?? ""
                return "<figure\(id)>\(rendered)<figcaption>\(number)\(escape(caption))</figcaption></figure>\n"
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
            let target = analysis.crossReferences.target(forBlockID: block.id)
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
            let id = target.map { " id=\"\(escape($0.key))\"" } ?? ""
            let caption = target.map { "<caption>\(escape($0.label))</caption>" } ?? ""
            return "<table\(id)>\(caption)<thead><tr>\(header)</tr></thead><tbody>\(rows)</tbody></table>\n"
        case .unorderedList, .orderedList:
            return ""
        }
    }

    private static func inline(_ markdown: String, analysis: MarkdownAnalysis,
                               context: DocumentContext) -> String {
        let cross = context.crossReferences?.placeholders(in: markdown)
        let linked = cross?.text ?? markdown
        let cited = context.markdownDialect == .extended && linked.contains("[@")
            ? MarkdownCitationCatalog.resolved(for: context)?.replaceInline(linked) ?? linked
            : linked
        let extensions: (text: String, items: [(String, MarkdownInlineExtensions.Item)]) = context.markdownDialect == .extended
            ? MarkdownInlineExtensions.placeholders(in: cited) : (cited, [])
        let emoji = context.markdownDialect == .extended
            ? MarkdownEmoji.replace(in: extensions.text) : extensions.text
        let layout = MarkdownImageLayout.parse(
            MarkdownRenderer.resolveReferences(
                in: MarkdownSafeHTML.previewMarkdown(emoji), using: analysis.references))
        let math: (text: String, formulas: [(String, MarkdownMath.Formula)]) = context.markdownDialect == .extended
            ? MarkdownMath.placeholders(in: layout.markdown) : (layout.markdown, [])
        let resolved = math.text
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: resolved, options: options) else {
            var fallback = escape(resolved)
            for (token, formula) in math.formulas {
                fallback = fallback.replacingOccurrences(of: token,
                    with: mathImage(formula) ?? escape(formula.source))
            }
            for (token, target) in cross?.targets ?? [] {
                fallback = fallback.replacingOccurrences(of: token,
                    with: "<a href=\"#\(escape(target.key))\">\(escape(target.label))</a>")
            }
            for (token, item) in extensions.items {
                fallback = fallback.replacingOccurrences(of: token,
                    with: "<\(item.kind.rawValue)>\(escape(MarkdownEmoji.replace(in: item.content)))</\(item.kind.rawValue)>")
            }
            return fallback
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
                run = "<a href=\"\(escape(linkDestination(destination, context: context)))\">\(run)</a>"
            }
            html += run
        }
        for (token, formula) in math.formulas {
            html = html.replacingOccurrences(of: token,
                with: mathImage(formula) ?? escape(formula.source))
        }
        for (token, target) in cross?.targets ?? [] {
            html = html.replacingOccurrences(of: token,
                with: "<a href=\"#\(escape(target.key))\">\(escape(target.label))</a>")
        }
        for (token, item) in extensions.items {
            html = html.replacingOccurrences(of: token,
                with: "<\(item.kind.rawValue)>\(escape(MarkdownEmoji.replace(in: item.content)))</\(item.kind.rawValue)>")
        }
        return html
    }

    private static func footnoteHTML(_ text: String, analysis: MarkdownAnalysis) -> String {
        let source = text as NSString
        let expression = MarkdownFootnoteIndex.referenceExpression
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
        guard !Task<Never, Never>.isCancelled, url.scheme == nil,
              let fileURL = context.resolveLocalResource(url.relativeString) else { return nil }
        guard case .embedBase64 = activeImages else { return activeImages.destination(for: fileURL) }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
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

    private static func mediaDestination(_ fileURL: URL) -> String? {
        guard case .embedBase64 = activeImages else { return activeImages.destination(for: fileURL) }
        guard let outputURL = activeOutputURL else { return fileURL.absoluteString }
        return relativePath(from: outputURL.deletingLastPathComponent(), to: fileURL)
    }

    /// Local attachment links follow the same mapping as images, keeping `#`/`?` suffixes.
    private static func linkDestination(_ destination: String, context: DocumentContext) -> String {
        if case .embedBase64 = activeImages { return destination }
        let split = destination.firstIndex(where: { $0 == "#" || $0 == "?" })
        let path = split.map { String(destination[..<$0]) } ?? destination
        guard let fileURL = context.resolveLocalResource(path),
              let mapped = activeImages.destination(for: fileURL) else { return destination }
        return mapped + (split.map { String(destination[$0...]) } ?? "")
    }

    /// A percent-encoded relative URL path from `directory` to `fileURL`.
    static func relativePath(from directory: URL, to fileURL: URL) -> String {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let target = fileURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        var common = 0
        while common < base.count, common < target.count - 1, base[common] == target[common] { common += 1 }
        return hrefPath(Array(repeating: "..", count: base.count - common) + target[common...])
    }

    /// Encodes each component so names containing `:`, `#`, `?` or spaces stay one relative path.
    static func hrefPath<Components: Sequence<String>>(_ components: Components) -> String {
        components.map { $0.addingPercentEncoding(withAllowedCharacters: hrefComponentAllowed) ?? $0 }
            .joined(separator: "/")
    }

    private static let hrefComponentAllowed = CharacterSet.urlPathAllowed
        .subtracting(CharacterSet(charactersIn: "/:;?#"))

    private static func safeLink(_ value: Any) -> String? {
        let text = (value as? URL)?.relativeString ?? value as? String
        guard let text, let url = URL(string: text),
              url.scheme == nil || ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return text
    }

    /// The front matter's `lang:` when it is a language tag, otherwise the app's localization,
    /// which is the language of the generated headings such as the footnotes title.
    static func documentLanguage(_ analysis: MarkdownAnalysis) -> String {
        if let raw = analysis.frontMatter?.raw,
           let value = FrontMatterProperties.items(in: raw)
            .first(where: { $0.key.lowercased() == "lang" })?.value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")),
           value.range(of: #"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$"#, options: .regularExpression) != nil {
            return value
        }
        return Bundle.main.preferredLocalizations.first(where: { $0 != "Base" })
            ?? Bundle.main.developmentLocalization ?? "ja"
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

/// Pure computation runs outside the main actor; cancellation is forwarded to its worker.
enum DocumentWork {
    static func perform<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Once the final mutation starts, completion wins over cancellation. The
    /// operation may check cancellation during preparation, but not after commit.
    static func commit<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    @MainActor
    static func loadHTML(_ html: String) async throws -> NSAttributedString {
        try Task.checkCancellation()
        let state = HTMLLoadState()
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard state.install(continuation) else { return }
                NSAttributedString.loadFromHTML(string: html, options: [.timeout: 30]) { attributed, _, error in
                    if let attributed { state.finish(.success(AttributedTransfer(attributed))) }
                    else { state.finish(.failure(error ?? RichTextImportError.invalidDocument)) }
                }
            }
        } onCancel: { state.cancel() }
        try Task.checkCancellation()
        return value.value
    }
}

/// Immutable attributed text is exclusively owned by the next pipeline stage.
final class AttributedTransfer: @unchecked Sendable {
    let value: NSAttributedString
    init(_ value: NSAttributedString) { self.value = value }
}

private final class HTMLLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AttributedTransfer, Error>?
    private var cancelled = false

    func install(_ value: CheckedContinuation<AttributedTransfer, Error>) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); value.resume(throwing: CancellationError()); return false }
        continuation = value
        lock.unlock()
        return true
    }

    func finish(_ result: Result<AttributedTransfer, Error>) {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        value?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let value = continuation
        continuation = nil
        lock.unlock()
        value?.resume(throwing: CancellationError())
    }
}
