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

    let id: Int
    let parentID: Int?
    let kind: Kind
    let content: String
    let sourceRange: NSRange
    let codeLanguage: String?
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

    private static let listPattern = try! NSRegularExpression(pattern: #"^( *)([-+*]|[0-9]{1,9}[.)])[ \t]+(.*)$"#)

    private static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = sourceLines(markdown)
        var result: [MarkdownBlock] = []
        var listAncestors: [(indent: Int, id: Int)] = []
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
                    codeLanguage: fence.language
                ))
                listAncestors.removeAll()
                quoteAncestors.removeAll()
                continue
            }

            let id = result.count
            var parentID: Int?
            var kind: MarkdownBlock.Kind
            var content = line.text

            if trimmed.isEmpty {
                kind = .blank
                content = ""
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
                content = list.content
                while let last = listAncestors.last, last.indent >= list.indent {
                    listAncestors.removeLast()
                }
                parentID = listAncestors.last?.id
                listAncestors.append((list.indent, id))
                quoteAncestors.removeAll()
            } else {
                kind = .paragraph
            }

            if !isList(kind) { listAncestors.removeAll() }
            if kind != .quote { quoteAncestors.removeAll() }
            result.append(MarkdownBlock(
                id: id, parentID: parentID, kind: kind, content: content,
                sourceRange: line.range, codeLanguage: nil
            ))
            index += 1
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

    private static func parseList(_ line: String) -> (kind: MarkdownBlock.Kind, content: String, indent: Int)? {
        let source = line as NSString
        guard let match = listPattern.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else {
            return nil
        }
        let indent = source.substring(with: match.range(at: 1)).count
        let marker = source.substring(with: match.range(at: 2))
        let content = source.substring(with: match.range(at: 3))
        if let number = Int(marker.dropLast()) {
            return (.orderedList(number: number), content, indent)
        }
        return (.unorderedList, content, indent)
    }

    private static func isList(_ kind: MarkdownBlock.Kind) -> Bool {
        switch kind {
        case .unorderedList, .orderedList: true
        default: false
        }
    }
}
