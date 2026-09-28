import AppKit
import Foundation

struct MarkdownPlainTextOptions {
    var linkDestinations = false
    var footnotes = true
    var imageDescriptions = true
}

@MainActor
enum MarkdownPlainTextExporter {
    private static let footnoteDefinition = try! NSRegularExpression(
        pattern: #"^\[\^([^\]]+)\]:[ \t]*(.*)$"#
    )
    private static let footnoteReference = try! NSRegularExpression(
        pattern: #"\[\^([^\]]+)\]"#
    )

    static func render(_ markdown: String, options: MarkdownPlainTextOptions) -> String {
        let (body, notes) = extractFootnotes(markdown)
        let analysis = MarkdownAnalysis(body)
        var parts = analysis.rootBlocks.compactMap {
            block($0, analysis: analysis, options: options)
        }
        if options.footnotes, !notes.isEmpty {
            parts.append(notes.map {
                "[\($0.id)] \(inline($0.text, analysis: analysis, options: options))"
            }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n")
    }

    private static func block(_ block: MarkdownBlock, analysis: MarkdownAnalysis,
                              options: MarkdownPlainTextOptions) -> String? {
        switch block.kind {
        case .blank, .horizontalRule: return nil
        case .heading, .paragraph:
            return inline(MarkdownRenderer.paragraphContent(block), analysis: analysis, options: options)
        case .quote:
            return analysis.children(of: block).compactMap {
                self.block($0, analysis: analysis, options: options)
            }.joined(separator: "\n\n")
        case .unorderedList, .orderedList:
            let content = block.task?.content ?? MarkdownRenderer.paragraphContent(block)
            let item = inline(content, analysis: analysis, options: options)
            let children = analysis.children(of: block).compactMap {
                self.block($0, analysis: analysis, options: options)
            }
            return ([item] + children).joined(separator: "\n")
        case .codeBlock: return block.content
        case .table:
            guard let table = block.table else { return nil }
            let rows = [table.header] + table.rows
            return rows.map { row in
                row.map { inline($0, analysis: analysis, options: options) }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }

    private static func inline(_ markdown: String, analysis: MarkdownAnalysis,
                               options: MarkdownPlainTextOptions) -> String {
        let references = replaceFootnoteReferences(in: markdown, include: options.footnotes)
        let resolved = MarkdownRenderer.resolveReferences(in: references, using: analysis.references)
        let parsing = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: resolved, options: parsing) else {
            return resolved
        }
        let value = NSAttributedString(parsed)
        let source = value.string as NSString
        var result = ""
        var activeLink: String?
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            let link = (attributes[.link] as? URL)?.relativeString ?? attributes[.link] as? String
            if activeLink != link {
                if let activeLink, options.linkDestinations { result += " (\(activeLink))" }
                activeLink = link
            }
            if attributes[.imageURL] != nil {
                if options.imageDescriptions {
                    result += (attributes[.alternateDescription] as? String)
                        ?? source.substring(with: range)
                }
            } else {
                result += source.substring(with: range)
            }
        }
        if let activeLink, options.linkDestinations { result += " (\(activeLink))" }
        return result
    }

    private static func replaceFootnoteReferences(in text: String, include: Bool) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        let codeSpans = MarkdownInlineSyntax.codeSpanRanges(in: text)
        for match in footnoteReference.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            if codeSpans.contains(where: { NSLocationInRange(match.range.location, $0) }) { continue }
            let id = source.substring(with: match.range(at: 1))
            result.replaceCharacters(in: match.range, with: include ? "[\(id)]" : "")
        }
        return result as String
    }

    private static func extractFootnotes(_ markdown: String) -> (String, [(id: String, text: String)]) {
        let lines = markdown.components(separatedBy: "\n")
        let codeRanges = MarkdownAnalysis(markdown).blocks.compactMap { block -> NSRange? in
            if case .codeBlock = block.kind { return block.sourceRange }
            return nil
        }
        var lineOffsets: [Int] = []
        var offset = 0
        for line in lines {
            lineOffsets.append(offset)
            offset += (line as NSString).length + 1
        }
        var body: [String] = []
        var notes: [(id: String, text: String)] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let source = line as NSString
            let insideCode = codeRanges.contains { NSLocationInRange(lineOffsets[index], $0) }
            if !insideCode, let match = footnoteDefinition.firstMatch(in: line,
                range: NSRange(location: 0, length: source.length)) {
                let id = source.substring(with: match.range(at: 1))
                var text = source.substring(with: match.range(at: 2))
                index += 1
                while index < lines.count && (lines[index].hasPrefix("    ") || lines[index].hasPrefix("\t")) {
                    text += " " + lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                }
                notes.append((id, text))
            } else {
                body.append(line)
                index += 1
            }
        }
        return (body.joined(separator: "\n"), notes)
    }
}
