import AppKit
import Foundation

@MainActor
enum MarkdownRenderer {
    static func render(_ markdown: String) -> NSAttributedString {
        let analysis = MarkdownAnalysis(markdown)
        return renderSequence(analysis.rootBlocks, in: analysis)
    }

    static func renderLeaf(_ block: MarkdownBlock) -> NSAttributedString {
        render(block)
    }

    static func renderTableCell(_ markdown: String) -> NSAttributedString {
        inline(markdown, baseFont: .systemFont(ofSize: 14))
    }

    private static func renderSequence(_ blocks: [MarkdownBlock], in analysis: MarkdownAnalysis) -> NSAttributedString {
        let output = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            output.append(renderTree(block, in: analysis))
            if index < blocks.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }
        return output
    }

    private static func renderTree(_ block: MarkdownBlock, in analysis: MarkdownAnalysis) -> NSAttributedString {
        let children = analysis.children(of: block)
        if block.kind == .quote {
            return quote(renderSequence(children, in: analysis))
        }
        let output = NSMutableAttributedString(attributedString: render(block))
        if !children.isEmpty {
            output.append(NSAttributedString(string: "\n"))
            output.append(renderSequence(children, in: analysis))
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

    private static func render(_ block: MarkdownBlock) -> NSAttributedString {
        switch block.kind {
        case .blank:
            return NSAttributedString(string: "")
        case .horizontalRule:
            return NSAttributedString(
                string: "────────────────────────",
                attributes: baseAttributes(font: .systemFont(ofSize: 13), color: .separatorColor)
            )
        case .codeBlock:
            var attributes = baseAttributes(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            attributes[.backgroundColor] = NSColor.controlBackgroundColor
            return NSAttributedString(string: block.content, attributes: attributes)
        case .table:
            guard let table = block.table else { return NSAttributedString(string: "") }
            return NSAttributedString(string: ([table.header] + table.rows)
                .map { $0.joined(separator: "\t") }.joined(separator: "\n"))
        case let .heading(level):
            let sizes: [CGFloat] = [28, 23, 20, 18, 16, 15]
            return inline(
                paragraphContent(block),
                baseFont: .systemFont(ofSize: sizes[level - 1], weight: level < 3 ? .bold : .semibold),
                paragraphSpacing: level < 3 ? 14 : 9
            )
        case .quote:
            return NSAttributedString(string: "")
        case .unorderedList:
            let task = block.task
            let content = inline(paragraphContent(block, content: task?.content), baseFont: .systemFont(ofSize: 15))
            let prefix = task.map { $0.isChecked ? "☑ 完了  " : "☐ 未完了  " } ?? "•  "
            content.insert(NSAttributedString(string: prefix, attributes: baseAttributes(font: .systemFont(ofSize: 15))), at: 0)
            applyListIndent(to: content, depth: block.nestingDepth)
            return content
        case let .orderedList(number):
            let task = block.task
            let content = inline(paragraphContent(block, content: task?.content), baseFont: .systemFont(ofSize: 15))
            let prefix = task.map { "\(number).  " + ($0.isChecked ? "☑ 完了  " : "☐ 未完了  ") }
                ?? "\(number).  "
            content.insert(NSAttributedString(string: prefix, attributes: baseAttributes(font: .systemFont(ofSize: 15))), at: 0)
            applyListIndent(to: content, depth: block.nestingDepth)
            return content
        case .paragraph:
            let content = inline(paragraphContent(block), baseFont: .systemFont(ofSize: 15))
            if block.parentID != nil {
                applyContinuationIndent(to: content, depth: block.nestingDepth)
            }
            return content
        }
    }

    private static func paragraphContent(_ block: MarkdownBlock, content: String? = nil) -> String {
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
        paragraphSpacing: CGFloat = 8
    ) -> NSMutableAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let parsed = (try? AttributedString(markdown: markdown, options: options))
            .map(NSAttributedString.init) ?? NSAttributedString(string: markdown)
        let result = NSMutableAttributedString(attributedString: parsed)
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

        return result
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
