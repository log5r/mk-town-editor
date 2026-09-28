import AppKit
import Foundation

struct MarkdownBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        case quote
        case unorderedList
        case orderedList(number: Int)
        case codeBlock
        case horizontalRule
        case blank
    }

    let kind: Kind
    let content: String
}

enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var codeLines: [String] = []
        var isInCodeBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if isInCodeBlock {
                    blocks.append(MarkdownBlock(kind: .codeBlock, content: codeLines.joined(separator: "\n")))
                    codeLines.removeAll(keepingCapacity: true)
                }
                isInCodeBlock.toggle()
                continue
            }

            if isInCodeBlock {
                codeLines.append(line)
                continue
            }

            blocks.append(parseLine(line, trimmed: trimmed))
        }

        if isInCodeBlock {
            blocks.append(MarkdownBlock(kind: .codeBlock, content: codeLines.joined(separator: "\n")))
        }

        return blocks
    }

    private static func parseLine(_ line: String, trimmed: String) -> MarkdownBlock {
        guard !trimmed.isEmpty else {
            return MarkdownBlock(kind: .blank, content: "")
        }

        let headingMarks = trimmed.prefix(while: { $0 == "#" })
        if (1...6).contains(headingMarks.count), trimmed.dropFirst(headingMarks.count).hasPrefix(" ") {
            let content = String(trimmed.dropFirst(headingMarks.count + 1))
            return MarkdownBlock(kind: .heading(level: headingMarks.count), content: content)
        }

        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return MarkdownBlock(kind: .horizontalRule, content: "")
        }

        if trimmed.hasPrefix("> ") {
            return MarkdownBlock(kind: .quote, content: String(trimmed.dropFirst(2)))
        }

        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            return MarkdownBlock(kind: .unorderedList, content: String(trimmed.dropFirst(2)))
        }

        if let markerRange = trimmed.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            let marker = trimmed[markerRange]
            let number = Int(marker.prefix(while: { $0.isNumber })) ?? 1
            return MarkdownBlock(
                kind: .orderedList(number: number),
                content: String(trimmed[markerRange.upperBound...])
            )
        }

        return MarkdownBlock(kind: .paragraph, content: line)
    }
}

@MainActor
enum MarkdownRenderer {
    static func render(_ markdown: String) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let blocks = MarkdownBlockParser.parse(markdown)

        for (index, block) in blocks.enumerated() {
            let rendered = render(block)
            output.append(rendered)
            if index < blocks.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }

        return output
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
        case let .heading(level):
            let sizes: [CGFloat] = [28, 23, 20, 18, 16, 15]
            return inline(
                block.content,
                baseFont: .systemFont(ofSize: sizes[level - 1], weight: level < 3 ? .bold : .semibold),
                paragraphSpacing: level < 3 ? 14 : 9
            )
        case .quote:
            let content = inline(block.content, baseFont: .systemFont(ofSize: 15), color: .secondaryLabelColor)
            content.insert(NSAttributedString(string: "│  ", attributes: baseAttributes(font: .systemFont(ofSize: 15), color: .tertiaryLabelColor)), at: 0)
            return content
        case .unorderedList:
            let content = inline(block.content, baseFont: .systemFont(ofSize: 15))
            content.insert(NSAttributedString(string: "•  ", attributes: baseAttributes(font: .systemFont(ofSize: 15))), at: 0)
            applyListIndent(to: content)
            return content
        case let .orderedList(number):
            let content = inline(block.content, baseFont: .systemFont(ofSize: 15))
            content.insert(NSAttributedString(string: "\(number).  ", attributes: baseAttributes(font: .systemFont(ofSize: 15))), at: 0)
            applyListIndent(to: content)
            return content
        case .paragraph:
            return inline(block.content, baseFont: .systemFont(ofSize: 15))
        }
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
            guard let intent = value as? InlinePresentationIntent else { return }
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

    private static func applyListIndent(to text: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 12
        paragraph.headIndent = 32
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = 4
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
    }
}
