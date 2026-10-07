import Foundation

enum MarkdownLineContinuation {
    private static let quotePattern = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)+"#)
    private static let listPattern = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-+*]|([0-9]{1,9})([.)]))([ \t]+)(\[[ xX]\](?:[ \t]+|$))?"#
    )

    static func edit(in text: String, selection: NSRange, analysis: MarkdownAnalysis? = nil,
                     allowsAnalysis: Bool = true) -> MarkdownEdit? {
        let source = text as NSString
        guard selection.length == 0, selection.location <= source.length else { return nil }
        let lineRange = source.lineRange(for: selection)
        let lineStart = lineRange.location
        let lineEnd = NSMaxRange(lineRange)
        let contentEnd = lineEnd - lineEndingLength(in: source, at: lineEnd)
        guard selection.location <= contentEnd else { return nil }
        let line = source.substring(with: NSRange(location: lineStart, length: contentEnd - lineStart))
        let lineSource = line as NSString
        let full = NSRange(location: 0, length: lineSource.length)
        let quoteRange = quotePattern.firstMatch(in: line, range: full)?.range
        let quotePrefix = quoteRange.map { lineSource.substring(with: $0) } ?? ""
        let remainder = lineSource.substring(from: (quotePrefix as NSString).length)
        let restSource = remainder as NSString
        let list = listPattern.firstMatch(in: remainder,
                                          range: NSRange(location: 0, length: restSource.length))
        guard !quotePrefix.isEmpty || list != nil else { return nil }
        guard !MarkdownEditingContext.isInCode(at: lineStart, source: text,
            analysis: analysis, allowsAnalysis: allowsAnalysis) else { return nil }

        let listPrefix = list.map { restSource.substring(with: $0.range) } ?? ""
        let prefix = quotePrefix + listPrefix
        let prefixLength = (prefix as NSString).length
        guard selection.location >= lineStart + prefixLength else { return nil }
        let content = restSource.substring(from: (listPrefix as NSString).length)
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let replacement: String
            if list != nil {
                replacement = quotePrefix
            } else if let lastMarker = quotePrefix.lastIndex(of: ">") {
                replacement = String(quotePrefix[..<lastMarker])
            } else {
                return nil
            }
            return MarkdownEdit(range: NSRange(location: lineStart, length: prefixLength),
                                replacement: replacement,
                                selection: NSRange(location: lineStart + (replacement as NSString).length,
                                                   length: 0))
        }

        let continuation: String
        if let list {
            let marker = restSource.substring(with: list.range(at: 2))
            let indent = restSource.substring(with: list.range(at: 1))
            let spacing = restSource.substring(with: list.range(at: 5))
            let task = list.range(at: 6).location != NSNotFound ? "[ ] " : ""
            if let number = Int(marker.dropLast()), marker.last == "." || marker.last == ")" {
                guard number < 999_999_999 else { return nil }
                continuation = quotePrefix + indent + "\(number + 1)\(marker.last!)" + spacing + task
            } else {
                continuation = quotePrefix + indent + marker + spacing + task
            }
        } else {
            continuation = quotePrefix
        }
        let newline = text.contains("\r\n") ? "\r\n" : text.contains("\r") ? "\r" : "\n"
        let insertion = newline + continuation
        return MarkdownEdit(range: selection, replacement: insertion,
                            selection: NSRange(location: selection.location + (insertion as NSString).length,
                                               length: 0))
    }

    private static func lineEndingLength(in source: NSString, at end: Int) -> Int {
        guard end > 0 else { return 0 }
        if source.character(at: end - 1) == 10 {
            return end > 1 && source.character(at: end - 2) == 13 ? 2 : 1
        }
        return source.character(at: end - 1) == 13 ? 1 : 0
    }
}

/// A bounded lexical fallback for keystrokes while background analysis is pending.
enum MarkdownEditingContext {
    private static let fence = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)*(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+)?(`{3,}|~{3,})(.*)$"#)

    static func isInCode(at location: Int, source: String, analysis: MarkdownAnalysis?, allowsAnalysis: Bool) -> Bool {
        if let analysis = analysis ?? (allowsAnalysis ? MarkdownAnalysis(source) : nil) {
            return analysis.blocks.contains { $0.kind == .codeBlock && NSLocationInRange(location, $0.sourceRange) }
        }
        let text = source as NSString
        guard location >= 0, location <= text.length else { return true }
        let current = text.lineRange(for: NSRange(location: location, length: 0))
        let start = max(0, current.location - 8_192)
        // When the opening fence may precede the bound, decline structural completion.
        guard start == 0 else { return true }
        let currentLine = text.substring(with: current)
        if currentLine.hasPrefix("    ") || currentLine.hasPrefix("\t") ||
            fence.firstMatch(in: currentLine, range: NSRange(location: 0, length: currentLine.utf16.count)) != nil { return true }
        let prefix = text.substring(to: current.location)
        var opening: (Character, Int)?
        for line in prefix.components(separatedBy: .newlines) {
            let range = NSRange(location: 0, length: line.utf16.count)
            guard let match = fence.firstMatch(in: line, range: range) else { continue }
            let token = (line as NSString).substring(with: match.range(at: 1))
            let tail = (line as NSString).substring(with: match.range(at: 2))
            if let active = opening {
                if token.first == active.0, token.count >= active.1,
                   tail.trimmingCharacters(in: .whitespaces).isEmpty { opening = nil }
            } else if token.first != "`" || !tail.contains("`") {
                opening = (token.first!, token.count)
            }
        }
        return opening != nil
    }
}
