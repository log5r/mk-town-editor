import AppKit
import Foundation

@MainActor
enum MarkdownRenderer {
    /// プレビューではローカル画像を背景でデコードし、完了まで読み込み中の表示にする。
    /// 値は要求元のプレビューで、閉じた時に待機中のデコードを取り消すために使う。
    /// 書き出し・印刷では既定の `nil` のまま同期的にデコードし、画像を欠かさない。
    // Keep the getter and macro-generated storage on the renderer’s main actor.
    @TaskLocal static var localImageRequester: LocalImageRequester?

    nonisolated private static let referencePattern = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]]+)\](?:\[([^\]]*)\])?"#
    )

    static func render(_ markdown: String,
                       documentContext: DocumentContext = DocumentContext(fileURL: nil)) -> NSAttributedString {
        render(MarkdownAnalysis(markdown, dialect: documentContext.markdownDialect),
               documentContext: documentContext)
    }

    static func render(_ analysis: MarkdownAnalysis,
                       documentContext: DocumentContext = DocumentContext(fileURL: nil)) -> NSAttributedString {
        var context = documentContext
        context.markdownDialect = analysis.dialect
        context.crossReferences = analysis.crossReferences
        if analysis.dialect == .extended, context.citationCatalog == nil {
            context.citationCatalog = analysis.containsCitationSyntax
                ? MarkdownCitationCatalog.load(documentURL: context.fileURL) ?? .empty : .empty
        }
        let output = NSMutableAttributedString(attributedString:
            renderSequence(analysis.rootBlocks, in: analysis, context: context))
        if !analysis.footnotes.entries.isEmpty {
            output.append(NSAttributedString(string: "\n\n" + String(localized: "脚注") + "\n"))
            for note in analysis.footnotes.entries {
                let prefix = NSMutableAttributedString(string: "\(note.number). ")
                prefix.append(inline(note.content, baseFont: .systemFont(ofSize: 13),
                    references: analysis.references, context: context))
                let back = NSMutableAttributedString(string: " ↩")
                back.addAttribute(.link, value: URL(string: "mktown-footnote-back:///\(note.number)")!,
                    range: NSRange(location: 1, length: 1))
                prefix.append(back)
                prefix.append(NSAttributedString(string: "\n"))
                output.append(prefix)
            }
        }
        if analysis.dialect == .extended,
           let catalog = context.citationCatalog,
           catalog.hasCitation(in: analysis) {
            output.append(NSAttributedString(string: "\n\n" + String(localized: "参考文献") + "\n"))
            for (index, entry) in catalog.entries.enumerated() {
                output.append(NSAttributedString(string: "\(index + 1). \(entry.bibliographyText)\n"))
            }
        }
        return output
    }

    static func renderLeaf(_ block: MarkdownBlock, in analysis: MarkdownAnalysis,
                           showTaskPrefix: Bool = true,
                           documentContext: DocumentContext = DocumentContext(fileURL: nil)) -> NSAttributedString {
        var context = documentContext
        context.markdownDialect = analysis.dialect
        context.crossReferences = analysis.crossReferences
        return render(block, references: analysis.references, footnotes: analysis.footnotes,
               showTaskPrefix: showTaskPrefix,
               context: context)
    }

    static func renderTableCell(_ markdown: String, in analysis: MarkdownAnalysis,
                                documentContext: DocumentContext = DocumentContext(fileURL: nil)) -> NSAttributedString {
        var context = documentContext
        context.markdownDialect = analysis.dialect
        context.crossReferences = analysis.crossReferences
        return inline(markdown, baseFont: .systemFont(ofSize: 14), references: analysis.references,
               footnotes: analysis.footnotes,
               context: context)
    }

    static func renderCallout(_ block: MarkdownBlock, in analysis: MarkdownAnalysis,
                              documentContext: DocumentContext) -> NSAttributedString {
        var context = documentContext
        context.markdownDialect = analysis.dialect
        context.crossReferences = analysis.crossReferences
        return renderTree(block, in: analysis, context: context)
    }

    private static func renderSequence(_ blocks: [MarkdownBlock], in analysis: MarkdownAnalysis,
                                       context: DocumentContext) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            output.append(renderTree(block, in: analysis, context: context))
            if index < blocks.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }
        return output
    }

    private static func renderTree(_ block: MarkdownBlock, in analysis: MarkdownAnalysis,
                                   context: DocumentContext) -> NSAttributedString {
        let children = analysis.children(of: block)
        if block.kind == .quote {
            let content = renderSequence(children, in: analysis, context: context)
            if let callout = block.calloutKind {
                let result = NSMutableAttributedString(string: "\(callout.title)\n",
                    attributes: baseAttributes(font: .systemFont(ofSize: 15, weight: .semibold),
                                               color: .labelColor))
                result.append(content)
                return quote(result)
            }
            return quote(content)
        }
        let output = NSMutableAttributedString(attributedString: render(block, references: analysis.references,
                                                                       footnotes: analysis.footnotes,
                                                                       context: context))
        if !children.isEmpty {
            output.append(NSAttributedString(string: "\n"))
            output.append(renderSequence(children, in: analysis, context: context))
        }
        return output
    }

    private static func quote(_ content: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let source = content.string as NSString
        let prefix = NSAttributedString(
            string: "│  ",
            attributes: baseAttributes(font: .systemFont(ofSize: 15), color: .tertiaryLabelColor)
        )
        var cursor = 0
        repeat {
            result.append(prefix)
            let newline = source.range(of: "\n", range: NSRange(location: cursor, length: source.length - cursor))
            let end = newline.location == NSNotFound ? source.length : newline.location
            if end > cursor {
                result.append(content.attributedSubstring(from: NSRange(location: cursor, length: end - cursor)))
            }
            if newline.location == NSNotFound { break }
            result.append(NSAttributedString(string: "\n"))
            cursor = end + 1
        } while cursor <= source.length
        return result
    }

    private static func render(
        _ block: MarkdownBlock, references: [String: MarkdownReference],
        footnotes: MarkdownFootnoteIndex, showTaskPrefix: Bool = true,
        context: DocumentContext
    ) -> NSAttributedString {
        switch block.kind {
        case .blank:
            return NSAttributedString(string: "")
        case .horizontalRule:
            return NSAttributedString(
                string: "────────────────────────",
                attributes: baseAttributes(font: .systemFont(ofSize: 13), color: .separatorColor)
            )
        case .codeBlock:
            return CodeSyntaxHighlighter.render(block.content, language: block.codeLanguage,
                                         tokens: context.codeSyntaxTokens?[block.id])
        case .table:
            guard let table = block.table else { return NSAttributedString(string: "") }
            let content = ([table.header] + table.rows)
                .map { $0.joined(separator: "\t") }.joined(separator: "\n")
            let prefix = context.crossReferences?.target(forBlockID: block.id).map { "\($0.label)\n" } ?? ""
            return NSAttributedString(string: prefix + content)
        case let .heading(level):
            let sizes: [CGFloat] = [28, 23, 20, 18, 16, 15]
            return inline(
                paragraphContent(block),
                baseFont: .systemFont(ofSize: sizes[level - 1], weight: level < 3 ? .bold : .semibold),
                paragraphSpacing: level < 3 ? 14 : 9, references: references,
                footnotes: footnotes, context: context
            )
        case .quote:
            return NSAttributedString(string: "")
        case .unorderedList:
            let task = block.task
            let content = inline(paragraphContent(block, content: task?.content),
                                 baseFont: .systemFont(ofSize: 15), references: references,
                                 footnotes: footnotes, context: context)
            if showTaskPrefix || task == nil {
                let prefix = task.map { $0.isChecked ? String(localized: "☑ 完了  ") : String(localized: "☐ 未完了  ") } ?? "•  "
                content.insert(NSAttributedString(string: prefix, attributes: baseAttributes(font: .systemFont(ofSize: 15))), at: 0)
            }
            applyListIndent(to: content, depth: block.nestingDepth)
            return content
        case let .orderedList(number):
            let task = block.task
            let content = inline(paragraphContent(block, content: task?.content),
                                 baseFont: .systemFont(ofSize: 15), references: references,
                                 footnotes: footnotes, context: context)
            let prefix = showTaskPrefix
                ? task.map { "\(number).  " + ($0.isChecked ? String(localized: "☑ 完了  ") : String(localized: "☐ 未完了  ")) }
                    ?? "\(number).  "
                : "\(number).  "
            content.insert(NSAttributedString(string: prefix,
                attributes: baseAttributes(font: .systemFont(ofSize: 15))), at: 0)
            applyListIndent(to: content, depth: block.nestingDepth)
            return content
        case .paragraph:
            if context.crossReferences?.markerBlockIDs.contains(block.id) == true {
                return NSAttributedString(string: "")
            }
            if let media = MarkdownMedia(block, dialect: context.markdownDialect) {
                let label = media.localURL(in: context) == nil
                    ? "\(media.label)（再生不可）" : media.label
                let result = NSMutableAttributedString(string: label)
                if let url = media.localURL(in: context) {
                    result.addAttribute(.link, value: url,
                        range: NSRange(location: 0, length: result.length))
                }
                return result
            }
            if let definitionList = MarkdownDefinitionList(block, dialect: context.markdownDialect) {
                let output = NSMutableAttributedString(string: "")
                for entry in definitionList.entries {
                    if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
                    let term = inline(entry.term, baseFont: .boldSystemFont(ofSize: 15),
                                      references: references, footnotes: footnotes, context: context)
                    output.append(term)
                    for definition in entry.definitions {
                        output.append(NSAttributedString(string: "\n    "))
                        output.append(inline(definition, baseFont: .systemFont(ofSize: 15),
                                             references: references, footnotes: footnotes, context: context))
                    }
                }
                return output
            }
            if context.markdownDialect == .extended,
               let formula = MarkdownMath.displayFormula(block.content) {
                let output = NSMutableAttributedString(attributedString:
                    MarkdownMathRenderer.attachment(formula, fontSize: 21)
                    ?? NSAttributedString(string: formula.source)
                )
                if let target = context.crossReferences?.target(forBlockID: block.id) {
                    output.append(NSAttributedString(string: "  \(target.label)"))
                }
                return output
            }
            let content = inline(paragraphContent(block), baseFont: .systemFont(ofSize: 15),
                                 captionStandaloneImage: true,
                                 references: references, footnotes: footnotes, context: context)
            if block.parentID != nil {
                applyContinuationIndent(to: content, depth: block.nestingDepth)
            }
            if let target = context.crossReferences?.target(forBlockID: block.id) {
                content.append(NSAttributedString(string: "\n\(target.label)"))
            }
            return content
        }
    }

    nonisolated static func paragraphContent(_ block: MarkdownBlock, content: String? = nil) -> String {
        let lines = (content ?? block.content).components(separatedBy: "\n")
        var result = ""
        for (index, line) in lines.enumerated() {
            var content = line
            if index < block.lineBreaks.count {
                let trailingSpaces = content.reversed().prefix(while: { $0 == " " }).count
                while content.last == " " || content.last == "\t" { content.removeLast() }
                if block.lineBreaks[index] == .hard && trailingSpaces < 2 && content.last == "\\" {
                    content.removeLast()
                }
            }
            result += content
            if index < block.lineBreaks.count {
                result += block.lineBreaks[index] == .hard ? "\n" : " "
            }
        }
        return result
    }

    private static func inline(
        _ markdown: String,
        baseFont: NSFont,
        color: NSColor = .textColor,
        paragraphSpacing: CGFloat = 8,
        captionStandaloneImage: Bool = false,
        references: [String: MarkdownReference] = [:],
        footnotes: MarkdownFootnoteIndex? = nil,
        context: DocumentContext
    ) -> NSMutableAttributedString {
        let cross = context.crossReferences?.placeholders(in: markdown)
        let linked = cross?.text ?? markdown
        let cited = context.markdownDialect == .extended && linked.contains("[@")
            ? MarkdownCitationCatalog.resolved(for: context)?.replaceInline(linked) ?? linked
            : linked
        let extensions: (text: String, items: [(String, MarkdownInlineExtensions.Item)]) = context.markdownDialect == .extended
            ? MarkdownInlineExtensions.placeholders(in: cited) : (cited, [])
        let emoji = context.markdownDialect == .extended
            ? MarkdownEmoji.replace(in: extensions.text) : extensions.text
        let layout = MarkdownImageLayout.parse(resolveReferences(
            in: MarkdownSafeHTML.previewMarkdown(emoji), using: references))
        let math: (text: String, formulas: [(String, MarkdownMath.Formula)]) = context.markdownDialect == .extended
            ? MarkdownMath.placeholders(in: layout.markdown) : (layout.markdown, [])
        let resolved = math.text
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: resolved, options: options))
            .map(NSAttributedString.init) ?? NSAttributedString(string: resolved)
        let result = NSMutableAttributedString(attributedString: parsed)
        for (token, formula) in math.formulas.reversed() {
            let range = (result.string as NSString).range(of: token)
            guard range.location != NSNotFound else { continue }
            result.replaceCharacters(in: range, with:
                MarkdownMathRenderer.attachment(formula, fontSize: baseFont.pointSize)
                    ?? NSAttributedString(string: formula.source))
        }
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes(baseAttributes(font: baseFont, color: color, paragraphSpacing: paragraphSpacing), range: fullRange)

        result.enumerateAttribute(.inlinePresentationIntent, in: fullRange) { value, range, _ in
            let intent = (value as? InlinePresentationIntent) ??
                (value as? NSNumber).map { InlinePresentationIntent(rawValue: $0.uintValue) }
            guard let intent else { return }
            var font = baseFont
            if intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent.contains(.code) {
                font = .monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
                result.addAttribute(.backgroundColor, value: NSColor.controlBackgroundColor, range: range)
            }
            if intent.contains(.strikethrough) {
                result.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            result.addAttribute(.font, value: font, range: range)
        }

        var images: [(NSRange, URL, String, CGFloat?)] = []
        var imageIndex = 0
        result.enumerateAttribute(.imageURL, in: fullRange) { value, range, _ in
            guard let url = value as? URL else { return }
            let alt = (result.attribute(.alternateDescription, at: range.location,
                                        effectiveRange: nil) as? String)
                ?? result.attributedSubstring(from: range).string
            let width = imageIndex < layout.widths.count ? layout.widths[imageIndex] : nil
            images.append((range, url, alt, width))
            imageIndex += 1
        }
        var renderedAttachment = false
        for (range, url, alt, width) in images.reversed() {
            let replacement: NSAttributedString
            let localFile = url.scheme == nil ? context.resolveLocalResource(url.relativeString) : nil
            let localLookup: LocalImageStore.Lookup? = localFile.map { fileURL in
                if let requester = localImageRequester {
                    return LocalImageStore.shared.lookup(fileURL, requester: requester)
                }
                return LocalImageCache.shared.image(at: fileURL).map(LocalImageStore.Lookup.image) ?? .unavailable
            }
            if let fileURL = localFile, case let .image(cached)? = localLookup {
                let image = (cached.copy() as? NSImage) ?? cached
                image.accessibilityDescription = alt
                let attachment = MarkdownImageAttachment()
                renderedAttachment = true
                attachment.image = sizedImage(image, width: width)
                attachment.bounds = NSRect(origin: .zero, size: attachment.image?.size ?? image.size)
                let value = NSMutableAttributedString(attachment: attachment)
                value.addAttribute(.alternateDescription, value: alt,
                                   range: NSRange(location: 0, length: value.length))
                if let link = MarkdownImageInspectionLink.make(fileURL) {
                    value.addAttribute(.link, value: link,
                        range: NSRange(location: 0, length: value.length))
                }
                replacement = value
            } else if ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      let image = RemoteImageStore.shared.image(for: url) {
                let attachment = MarkdownImageAttachment()
                renderedAttachment = true
                let accessibleImage = (image.copy() as? NSImage) ?? image
                accessibleImage.accessibilityDescription = alt
                attachment.image = sizedImage(accessibleImage, width: width)
                attachment.bounds = NSRect(origin: .zero, size: attachment.image?.size ?? image.size)
                let value = NSMutableAttributedString(attachment: attachment)
                value.addAttribute(.alternateDescription, value: alt,
                                   range: NSRange(location: 0, length: value.length))
                if let link = MarkdownImageInspectionLink.make(url) {
                    value.addAttribute(.link, value: link,
                        range: NSRange(location: 0, length: value.length))
                }
                replacement = value
            } else {
                let status: String
                if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    status = RemoteImageStore.shared.isEnabled
                        ? (RemoteImageStore.shared.hasFailed(url) ? String(localized: "画像を読み込めません") : String(localized: "画像を読み込み中"))
                        : String(localized: "外部画像の読込オフ")
                } else if case .loading? = localLookup {
                    status = String(localized: "画像を読み込み中")
                } else {
                    status = String(localized: "画像")
                }
                let value = NSMutableAttributedString(string: "\(status): \(alt)",
                                                      attributes: baseAttributes(font: baseFont, color: color,
                                                                                 paragraphSpacing: paragraphSpacing))
                value.addAttribute(.link, value: url, range: NSRange(location: 0, length: value.length))
                if case .loading? = localLookup {
                    value.addAttribute(.pendingLocalImage, value: true,
                                       range: NSRange(location: 0, length: value.length))
                }
                replacement = value
            }
            result.replaceCharacters(in: range, with: replacement)
        }

        if captionStandaloneImage, let caption = layout.standaloneCaption,
           renderedAttachment {
            result.append(NSAttributedString(string: "\n\(caption)", attributes:
                baseAttributes(font: .systemFont(ofSize: 12), color: .secondaryLabelColor,
                               paragraphSpacing: paragraphSpacing)))
        }

        MarkdownAutolink.apply(to: result)
        if let footnotes { applyFootnoteMarkers(to: result, footnotes: footnotes) }
        for (token, target) in (cross?.targets ?? []).reversed() {
            let range = (result.string as NSString).range(of: token)
            guard range.location != NSNotFound,
                  let url = URL(string: "mktown-crossref:///\(target.key)") else { continue }
            let replacement = NSAttributedString(string: target.label, attributes: [
                .font: baseFont, .foregroundColor: NSColor.linkColor, .link: url
            ])
            result.replaceCharacters(in: range, with: replacement)
        }
        for (token, item) in extensions.items.reversed() {
            let range = (result.string as NSString).range(of: token)
            guard range.location != NSNotFound else { continue }
            let inherited = result.attributes(at: range.location, effectiveRange: nil)
            let replacement = NSMutableAttributedString(string: MarkdownEmoji.replace(in: item.content),
                attributes: inherited)
            let contentRange = NSRange(location: 0, length: replacement.length)
            let inheritedFont = inherited[.font] as? NSFont ?? baseFont
            switch item.kind {
            case .mark:
                replacement.addAttribute(.backgroundColor,
                    value: NSColor.systemYellow.withAlphaComponent(0.35), range: contentRange)
            case .sup:
                replacement.addAttributes([.font: NSFont.systemFont(ofSize: inheritedFont.pointSize * 0.75),
                                           .baselineOffset: inheritedFont.pointSize * 0.3], range: contentRange)
            case .sub:
                replacement.addAttributes([.font: NSFont.systemFont(ofSize: inheritedFont.pointSize * 0.75),
                                           .baselineOffset: -inheritedFont.pointSize * 0.2], range: contentRange)
            }
            result.replaceCharacters(in: range, with: replacement)
        }
        return result
    }

    private static func sizedImage(_ image: NSImage, width: CGFloat?) -> NSImage {
        guard let width, image.size.width > 0, image.size.height > 0,
              let copy = image.copy() as? NSImage else { return image }
        copy.size = NSSize(width: width, height: image.size.height * width / image.size.width)
        return copy
    }

    private static func applyFootnoteMarkers(to result: NSMutableAttributedString,
                                             footnotes: MarkdownFootnoteIndex) {
        let expression = MarkdownFootnoteIndex.referenceExpression
        let source = result.string as NSString
        let matches = expression.matches(in: result.string,
            range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            let id = source.substring(with: match.range(at: 1))
            guard let note = footnotes.entry(for: id) else { continue }
            let intent = result.attribute(.inlinePresentationIntent,
                at: match.range.location, effectiveRange: nil)
            let parsedIntent = (intent as? InlinePresentationIntent)
                ?? (intent as? NSNumber).map { InlinePresentationIntent(rawValue: $0.uintValue) }
            guard parsedIntent?.contains(.code) != true,
                  result.attribute(.link, at: match.range.location, effectiveRange: nil) == nil else { continue }
            let marker = NSMutableAttributedString(string: String(note.number), attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .baselineOffset: 5,
                .foregroundColor: NSColor.linkColor,
                .link: URL(string: "mktown-footnote:///\(note.number)")!
            ])
            result.replaceCharacters(in: match.range, with: marker)
        }
    }

    nonisolated static func resolveReferences(
        in markdown: String, using references: [String: MarkdownReference]
    ) -> String {
        guard !references.isEmpty else { return markdown }
        let source = markdown as NSString
        let result = NSMutableString(string: markdown)
        let codeSpans = MarkdownInlineSyntax.codeSpanRanges(in: markdown)
        let matches = referencePattern.matches(in: markdown,
            range: NSRange(location: 0, length: source.length))
        for match in matches.reversed() {
            if codeSpans.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
            let end = NSMaxRange(match.range)
            if end < source.length, source.character(at: end) == 40 { continue }
            if match.range.location > 0 {
                let prefix = source.substring(to: match.range.location)
                if prefix.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1 { continue }
            }
            let label = source.substring(with: match.range(at: 2))
            let explicitRange = match.range(at: 3)
            let key = explicitRange.location == NSNotFound || explicitRange.length == 0
                ? label : source.substring(with: explicitRange)
            guard let reference = references[MarkdownAnalysis.normalizedReferenceLabel(key)] else { continue }
            let isImage = match.range(at: 1).length > 0
            let replacement = isImage
                ? "![\(label)](<\(reference.destination)>)"
                : "[\(label)](<\(reference.destination)>)"
            result.replaceCharacters(in: match.range, with: replacement)
        }
        return result as String
    }

    private static func baseAttributes(
        font: NSFont,
        color: NSColor = .textColor,
        paragraphSpacing: CGFloat = 8
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = paragraphSpacing
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private static func applyListIndent(to text: NSMutableAttributedString, depth: Int) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = CGFloat(12 + depth * 24)
        paragraph.headIndent = CGFloat(32 + depth * 24)
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
    }

    private static func applyContinuationIndent(to text: NSMutableAttributedString, depth: Int) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = CGFloat(8 + depth * 24)
        paragraph.headIndent = paragraph.firstLineHeadIndent
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
    }
}

struct MarkdownImageLayout {
    let markdown: String
    let widths: [CGFloat?]
    let standaloneCaption: String?

    private static let widthExpression = try! NSRegularExpression(
        pattern: #"^\{width=([1-9][0-9]{0,3})(?:px)?\}"#)

    static func parse(_ markdown: String) -> Self {
        let source = markdown as NSString
        let codeRanges = MarkdownInlineSyntax.codeSpanRanges(in: markdown)
        let expression = widthExpression
        var widths: [CGFloat?] = []
        var removals: [NSRange] = []
        var caption: String?
        let links = MarkdownLinkSyntax.inlineLinks(in: markdown).filter { link in
            link.isImage && !codeRanges.contains(where: { NSLocationInRange(link.range.location, $0) })
        }
        for link in links {
            let suffixStart = NSMaxRange(link.range)
            let suffix = source.substring(from: suffixStart)
            let match = expression.firstMatch(in: suffix,
                range: NSRange(location: 0, length: (suffix as NSString).length))
            let width = match.flatMap { Int((suffix as NSString).substring(with: $0.range(at: 1))) }
            widths.append(width.map(CGFloat.init))
            if let match {
                removals.append(NSRange(location: suffixStart, length: match.range.length))
            }
            let imageText = source.substring(with: link.range)
            let attributeText = match.map { (suffix as NSString).substring(with: $0.range) } ?? ""
            if links.count == 1,
               markdown.trimmingCharacters(in: .whitespacesAndNewlines) == imageText + attributeText {
                caption = source.substring(with: link.labelRange)
            }
        }
        let stripped = NSMutableString(string: markdown)
        for range in removals.reversed() { stripped.replaceCharacters(in: range, with: "") }
        return Self(markdown: stripped as String, widths: widths, standaloneCaption: caption)
    }
}

final class MarkdownImageAttachment: NSTextAttachment {
    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex charIndex: Int) -> CGRect {
        let original = bounds.size.width > 0 && bounds.size.height > 0
            ? bounds.size : image?.size ?? .zero
        guard original.width > 0, original.height > 0 else { return .zero }
        let availableWidth = max(1, lineFrag.maxX - position.x - 8)
        let scale = min(1, availableWidth / original.width)
        return CGRect(x: 0, y: 0, width: original.width * scale, height: original.height * scale)
    }
}

extension NSAttributedString.Key {
    /// 背景で読み込み中のローカル画像の仮表示。描画キャッシュはこの結果を保持しない。
    static let pendingLocalImage = NSAttributedString.Key("MKTownPendingLocalImage")
}

extension NSAttributedString {
    var containsPendingLocalImage: Bool {
        var found = false
        enumerateAttribute(.pendingLocalImage, in: NSRange(location: 0, length: length)) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
