import Foundation

enum MarkdownLineContinuation {
    private static let quotePattern = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)+"#)
    private static let listPattern = try! NSRegularExpression(
        pattern: #"^([ \t]*)([-+*]|([0-9]{1,9})([.)]))([ \t]+)(\[[ xX]\](?:[ \t]+|$))?"#
    )

    static func edit(in text: String, selection: NSRange) -> MarkdownEdit? {
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
        guard !MarkdownAnalysis(text).blocks.contains(where: {
            $0.kind == .codeBlock && NSLocationInRange(lineStart, $0.sourceRange)
        }) else { return nil }

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
