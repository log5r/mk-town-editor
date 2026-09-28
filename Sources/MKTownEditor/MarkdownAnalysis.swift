import Foundation

enum MarkdownLineBreak: Equatable {
    case soft
    case hard
}

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

    let id: Int
    let parentID: Int?
    let kind: Kind
    let content: String
    let sourceRange: NSRange
    let codeLanguage: String?
    let lineBreaks: [MarkdownLineBreak]
    let sourceIndent: String?
    let nestingDepth: Int
}

/// One snapshot of a document. Every block refers to the unchanged source text.
struct MarkdownAnalysis {
    let blocks: [MarkdownBlock]
    let positionMap: MarkdownPositionMap

    init(_ markdown: String) {
        positionMap = MarkdownPositionMap(markdown)
        blocks = Self.parse(markdown)
    }

    var rootBlocks: [MarkdownBlock] { blocks.filter { $0.parentID == nil } }

    func children(of block: MarkdownBlock) -> [MarkdownBlock] {
        blocks.filter { $0.parentID == block.id }
    }

    private struct SourceLine {
        let text: String
        let range: NSRange
    }

    private struct Fence {
        let marker: Character
        let length: Int
        let language: String?
    }

    private static let listPattern = try! NSRegularExpression(pattern: #"^([ \t]*)([-+*]|[0-9]{1,9}[.)])[ \t]+(.*)$"#)

    private static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = sourceLines(markdown)
        var result: [MarkdownBlock] = []
        var listAncestors: [(indent: Int, id: Int, depth: Int)] = []
        var quoteAncestors: [Int] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)

            if let fence = openingFence(trimmed) {
                index += 1
                var codeLines: [String] = []
                while index < lines.count && !isClosingFence(lines[index].text, for: fence) {
                    codeLines.append(lines[index].text)
                    index += 1
                }
                if index < lines.count { index += 1 }
                let end = lines[index - 1].range
                result.append(MarkdownBlock(
                    id: result.count, parentID: nil, kind: .codeBlock,
                    content: codeLines.joined(separator: "\n"),
                    sourceRange: NSRange(location: line.range.location, length: NSMaxRange(end) - line.range.location),
                    codeLanguage: fence.language, lineBreaks: [], sourceIndent: nil, nestingDepth: 0
                ))
                listAncestors.removeAll()
                quoteAncestors.removeAll()
                continue
            }

            let id = result.count
            var parentID: Int?
            var kind: MarkdownBlock.Kind
            var content = line.text
            var sourceRange = line.range
            var lineBreaks: [MarkdownLineBreak] = []
            var advance = 1
            var sourceIndent: String?
            var nestingDepth = 0

            if trimmed.isEmpty {
                kind = .blank
                content = ""
                if let parent = listAncestors.last, index + 1 < lines.count,
                   indentationWidth(lines[index + 1].text) > parent.indent {
                    parentID = parent.id
                    nestingDepth = parent.depth + 1
                }
            } else if let quote = parseQuote(trimmed) {
                kind = .quote
                content = quote.content
                parentID = quote.depth > 1 && quoteAncestors.count >= quote.depth - 1
                    ? quoteAncestors[quote.depth - 2] : nil
                quoteAncestors = Array(quoteAncestors.prefix(quote.depth - 1))
                quoteAncestors.append(id)
                listAncestors.removeAll()
            } else if let heading = parseHeading(trimmed) {
                kind = .heading(level: heading.level)
                content = heading.content
            } else if ["---", "***", "___"].contains(trimmed) {
                kind = .horizontalRule
                content = ""
            } else if let list = parseList(line.text) {
                kind = list.kind
                var parts = [list.content]
                var next = index + 1
                while next < lines.count && isParagraphContinuation(lines[next].text) &&
                    indentationWidth(lines[next].text) > list.indent {
                    lineBreaks.append(lineBreak(after: parts[parts.count - 1]))
                    parts.append(withoutLeadingIndent(lines[next].text))
                    next += 1
                }
                content = parts.joined(separator: "\n")
                sourceRange = NSRange(location: line.range.location,
                                      length: NSMaxRange(lines[next - 1].range) - line.range.location)
                advance = next - index
                while let last = listAncestors.last, last.indent >= list.indent {
                    listAncestors.removeLast()
                }
                parentID = listAncestors.last?.id
                nestingDepth = listAncestors.count
                sourceIndent = list.sourceIndent
                listAncestors.append((list.indent, id, nestingDepth))
                quoteAncestors.removeAll()
            } else {
                kind = .paragraph
                if let parent = listAncestors.last, indentationWidth(line.text) > parent.indent {
                    parentID = parent.id
                    nestingDepth = parent.depth + 1
                }
                var parts = [parentID == nil ? line.text : withoutLeadingIndent(line.text)]
                var next = index + 1
                while next < lines.count && isParagraphContinuation(lines[next].text) &&
                    (parentID == nil || indentationWidth(lines[next].text) > listAncestors.last!.indent) {
                    lineBreaks.append(lineBreak(after: parts[parts.count - 1]))
                    parts.append(parentID == nil ? lines[next].text :
                        withoutLeadingIndent(lines[next].text))
                    next += 1
                }
                content = parts.joined(separator: "\n")
                sourceRange = NSRange(location: line.range.location,
                                      length: NSMaxRange(lines[next - 1].range) - line.range.location)
                advance = next - index
            }

            if !isList(kind) && parentID == nil { listAncestors.removeAll() }
            if kind != .quote { quoteAncestors.removeAll() }
            result.append(MarkdownBlock(
                id: id, parentID: parentID, kind: kind, content: content,
                sourceRange: sourceRange, codeLanguage: nil, lineBreaks: lineBreaks,
                sourceIndent: sourceIndent, nestingDepth: nestingDepth
            ))
            index += advance
        }
        return result
    }

    private static func sourceLines(_ text: String) -> [SourceLine] {
        let source = text as NSString
        guard source.length > 0 else { return [SourceLine(text: "", range: NSRange(location: 0, length: 0))] }
        var result: [SourceLine] = []
        var cursor = 0
        while cursor < source.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                                for: NSRange(location: cursor, length: 0))
            result.append(SourceLine(
                text: source.substring(with: NSRange(location: start, length: contentsEnd - start)),
                range: NSRange(location: start, length: end - start)
            ))
            cursor = end
        }
        if [10, 13].contains(Int(source.character(at: source.length - 1))) {
            result.append(SourceLine(text: "", range: NSRange(location: source.length, length: 0)))
        }
        return result
    }

    private static func openingFence(_ line: String) -> Fence? {
        let prefix = line.prefix(while: { $0 == "`" || $0 == "~" })
        guard prefix.count >= 3, let marker = prefix.first, prefix.allSatisfy({ $0 == marker }) else {
            return nil
        }
        let info = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)
        return Fence(marker: marker, length: prefix.count, language: language)
    }

    private static func isClosingFence(_ line: String, for fence: Fence) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let markerRun = trimmed.prefix(while: { $0 == fence.marker })
        return markerRun.count >= fence.length && trimmed.dropFirst(markerRun.count).isEmpty
    }

    private static func parseHeading(_ line: String) -> (level: Int, content: String)? {
        let marks = line.prefix(while: { $0 == "#" })
        guard (1...6).contains(marks.count), line.dropFirst(marks.count).hasPrefix(" ") else { return nil }
        return (marks.count, String(line.dropFirst(marks.count + 1)))
    }

    private static func isParagraphContinuation(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && openingFence(trimmed) == nil && parseQuote(trimmed) == nil &&
            parseHeading(trimmed) == nil && !["---", "***", "___"].contains(trimmed) &&
            parseList(line) == nil
    }

    private static func lineBreak(after line: String) -> MarkdownLineBreak {
        let trailingSpaces = line.reversed().prefix(while: { $0 == " " }).count
        if trailingSpaces >= 2 { return .hard }
        let trailingBackslashes = line.reversed().prefix(while: { $0 == "\\" }).count
        return trailingBackslashes % 2 == 1 ? .hard : .soft
    }

    private static func parseQuote(_ line: String) -> (depth: Int, content: String)? {
        var remainder = line[...]
        var depth = 0
        while remainder.first == ">" {
            depth += 1
            remainder = remainder.dropFirst()
            if remainder.first == " " { remainder = remainder.dropFirst() }
        }
        return depth > 0 ? (depth, String(remainder)) : nil
    }

    private static func parseList(_ line: String) -> (kind: MarkdownBlock.Kind, content: String, indent: Int, sourceIndent: String)? {
        let source = line as NSString
        guard let match = listPattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else {
            return nil
        }
        let sourceIndent = source.substring(with: match.range(at: 1))
        let indent = indentationWidth(sourceIndent)
        let marker = source.substring(with: match.range(at: 2))
        let content = source.substring(with: match.range(at: 3))
        if let number = Int(marker.dropLast()) {
            return (.orderedList(number: number), content, indent, sourceIndent)
        }
        return (.unorderedList, content, indent, sourceIndent)
    }

    private static func indentationWidth(_ line: String) -> Int {
        var width = 0
        for character in line.prefix(while: { $0 == " " || $0 == "\t" }) {
            width += character == "\t" ? 4 - width % 4 : 1
        }
        return width
    }

    private static func withoutLeadingIndent(_ line: String) -> String {
        String(line.drop(while: { $0 == " " || $0 == "\t" }))
    }

    private static func isList(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .unorderedList, .orderedList: true
        default: false
        }
    }
}
