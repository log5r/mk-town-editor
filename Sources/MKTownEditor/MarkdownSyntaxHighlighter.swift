import AppKit
import Foundation

struct MarkdownSyntaxSpan: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case heading
        case code
        case link
        case marker
        case quoteMarker
        case listMarker
        case taskMarker
        case tableMarker
        /// 言語を指定したコードブロック内の字句。
        case codeToken(CodeSyntaxToken)
    }

    let range: NSRange
    let role: Role
}

enum MarkdownSyntaxHighlighter {
    private static let emphasisExpressions: [(String, NSRegularExpression)] =
        ["**", "__", "~~", "*", "_"].map { marker in
            let escaped = NSRegularExpression.escapedPattern(for: marker)
            let boundary = marker.count == 1 ? "(?<!\(escaped))" : ""
            let after = marker.count == 1 ? "(?!\(escaped))" : ""
            return (marker, try! NSRegularExpression(
                pattern: boundary + escaped + after + #"([^\n]+?)"# + boundary + escaped + after))
        }

    private static let quoteExpression = try! NSRegularExpression(pattern: #"^[ \t]*(?:>[ \t]*)+"#)
    private static let listExpression = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*>[ \t]*)*[ \t]*([-+*]|[0-9]{1,9}[.)])(?=[ \t])"#
    )
    private static let taskExpression = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*>[ \t]*)*[ \t]*(?:[-+*]|[0-9]{1,9}[.)])[ \t]+(\[[ xX]\])"#
    )
    private static let linkExpression = try! NSRegularExpression(
        pattern: #"(?<!!)\[[^\]\n]+\](?:\([^\n]*?\)|\[[^\]\n]*\])"#
    )

    static func spans(in text: String, analysis: MarkdownAnalysis? = nil,
                      codeSyntaxTokens: [Int: [CodeSyntaxTokenRange]]? = nil) -> [MarkdownSyntaxSpan] {
        let source = text as NSString
        let analysis = analysis ?? MarkdownAnalysis(text)
        // ブロックは位置順に並ぶため、コードブロックの範囲も位置順になる。包含判定は二分探索で行う。
        let codeBlocks = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
        var result: [MarkdownSyntaxSpan] = []
        for block in analysis.blocks {
            switch block.kind {
            case .heading:
                result.append(MarkdownSyntaxSpan(range: block.sourceRange, role: .heading))
            case .codeBlock:
                result += codeBlockSpans(block, in: source, tokens: codeSyntaxTokens?[block.id])
            case .horizontalRule:
                result.append(MarkdownSyntaxSpan(range: block.sourceRange, role: .marker))
            case .table:
                let range = block.sourceRange
                for offset in range.location..<NSMaxRange(range)
                where source.character(at: offset) == 124 {
                    result.append(MarkdownSyntaxSpan(range: NSRange(location: offset, length: 1),
                                                     role: .tableMarker))
                }
            default: break
            }
        }

        var cursor = 0
        while cursor < source.length {
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            if mayStartWithBlockMarker(source, lineRange: lineRange),
               !MarkdownInlineSyntax.intersects(NSRange(location: lineRange.location, length: 1),
                                                sortedRanges: codeBlocks) {
                for (expression, role, group) in [
                    (quoteExpression, MarkdownSyntaxSpan.Role.quoteMarker, 0),
                    (listExpression, .listMarker, 1),
                    (taskExpression, .taskMarker, 1)
                ] {
                    // 範囲の先頭が ^ に一致するため、行を部分文字列へ切り出さずに照合できる。
                    if let match = expression.firstMatch(in: text, range: lineRange) {
                        result.append(MarkdownSyntaxSpan(range: match.range(at: group), role: role))
                    }
                }
            }
            cursor = NSMaxRange(lineRange)
        }

        let codeSpans = MarkdownInlineSyntax.codeSpanRanges(in: text).filter { span in
            !MarkdownInlineSyntax.intersects(span, sortedRanges: codeBlocks)
        }
        result += codeSpans.map { MarkdownSyntaxSpan(range: $0, role: .code) }
        let excluded = mergedSortedRanges(codeBlocks, codeSpans)
        for match in linkExpression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard !isEscaped(source, at: match.range.location),
                  !MarkdownInlineSyntax.intersects(match.range, sortedRanges: excluded) else { continue }
            result.append(MarkdownSyntaxSpan(range: match.range, role: .link))
        }
        for (marker, expression) in emphasisExpressions {
            for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let markerLength = (marker as NSString).length
                let opening = NSRange(location: match.range.location, length: markerLength)
                let closing = NSRange(location: NSMaxRange(match.range) - markerLength, length: markerLength)
                guard !isEscaped(source, at: opening.location),
                      !isEscaped(source, at: closing.location),
                      !MarkdownInlineSyntax.intersects(opening, sortedRanges: excluded),
                      !MarkdownInlineSyntax.intersects(closing, sortedRanges: excluded) else { continue }
                result.append(MarkdownSyntaxSpan(range: opening, role: .marker))
                result.append(MarkdownSyntaxSpan(range: closing, role: .marker))
            }
        }
        return result
    }

    /// 言語を指定したフェンスのコードブロックは、フェンス行を `.code`、本文を字句ごとの色にする。
    /// 未対応の言語や、本文と原文の行が対応しない場合（タブの展開など）はブロック全体を `.code` にする。
    /// `tokens` は解析済みの字句（`DocumentSnapshot.codeSyntaxTokens`）。`nil` の場合はここで解析する。
    static func codeBlockSpans(_ block: MarkdownBlock, in source: NSString,
                               tokens precomputed: [CodeSyntaxTokenRange]? = nil) -> [MarkdownSyntaxSpan] {
        let whole = [MarkdownSyntaxSpan(range: block.sourceRange, role: .code)]
        guard block.codeFenceMarker != nil, !block.content.isEmpty,
              let language = CodeSyntaxAnalyzer.language(named: block.codeLanguage) else { return whole }
        let blockEnd = NSMaxRange(block.sourceRange)
        let opening = source.lineRange(for: NSRange(location: block.sourceRange.location, length: 0))
        // 本文の各行が原文のどこから始まるか。引用やリストの記号を除いた本文は、原文の行の末尾部分になる。
        var lines: [(content: Int, source: Int, length: Int)] = []
        var contentOffset = 0
        var cursor = NSMaxRange(opening)
        for line in block.content.components(separatedBy: "\n") {
            guard cursor < blockEnd || (cursor == blockEnd && line.isEmpty && cursor == source.length) else {
                return whole
            }
            let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
            var textEnd = NSMaxRange(lineRange)
            if textEnd > lineRange.location, source.character(at: textEnd - 1) == 0x0A { textEnd -= 1 }
            if textEnd > lineRange.location, source.character(at: textEnd - 1) == 0x0D { textEnd -= 1 }
            let length = (line as NSString).length
            let start = textEnd - length
            guard start >= lineRange.location,
                  source.substring(with: NSRange(location: start, length: length)) == line else { return whole }
            lines.append((contentOffset, start, length))
            contentOffset += length + 1
            cursor = NSMaxRange(lineRange)
        }
        var result = [MarkdownSyntaxSpan(range: opening, role: .code)]
        if cursor < blockEnd {
            result.append(MarkdownSyntaxSpan(range: NSRange(location: cursor, length: blockEnd - cursor), role: .code))
        }
        var lineIndex = 0
        let contentLength = (block.content as NSString).length
        for token in precomputed ?? CodeSyntaxAnalyzer.tokens(in: block.content, language: language) {
            guard NSMaxRange(token.range) <= contentLength else { continue }
            // 字句は位置順に並ぶ。複数行にまたがる字句（ブロックコメントなど）は行ごとに分ける。
            while lineIndex < lines.count - 1,
                  token.range.location >= lines[lineIndex].content + lines[lineIndex].length + 1 { lineIndex += 1 }
            var index = lineIndex
            while index < lines.count, lines[index].content < NSMaxRange(token.range) {
                let line = lines[index]
                let start = max(token.range.location, line.content)
                let end = min(NSMaxRange(token.range), line.content + line.length)
                if end > start {
                    result.append(MarkdownSyntaxSpan(
                        range: NSRange(location: line.source + start - line.content, length: end - start),
                        role: .codeToken(token.token)))
                }
                index += 1
            }
        }
        return result
    }

    /// 引用・リスト・タスクの記号で始まり得る行だけを正規表現で照合する。
    private static func mayStartWithBlockMarker(_ source: NSString, lineRange: NSRange) -> Bool {
        var index = lineRange.location
        let end = NSMaxRange(lineRange)
        while index < end {
            switch source.character(at: index) {
            case 0x20, 0x09: index += 1
            case 0x3E, 0x2D, 0x2B, 0x2A, 0x30...0x39: return true // > - + * 0-9
            default: return false
            }
        }
        return false
    }

    /// 位置順に並んだ2つの範囲列を、重なりを保ったまま位置順に統合する。
    private static func mergedSortedRanges(_ first: [NSRange], _ second: [NSRange]) -> [NSRange] {
        var merged: [NSRange] = []
        merged.reserveCapacity(first.count + second.count)
        var left = 0
        var right = 0
        while left < first.count || right < second.count {
            let next: NSRange
            if right == second.count || (left < first.count && first[left].location <= second[right].location) {
                next = first[left]
                left += 1
            } else {
                next = second[right]
                right += 1
            }
            if let last = merged.last, next.location < NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, next)
            } else {
                merged.append(next)
            }
        }
        return merged
    }

    /// 文字ごとに最後に指定された役割を求め、同じ役割が続く区間にまとめる。役割のない区間は `nil`。
    static func coloredRuns(_ spans: [MarkdownSyntaxSpan], length: Int)
        -> [(range: NSRange, role: MarkdownSyntaxSpan.Role?)] {
        guard length > 0 else { return [] }
        var roles: [MarkdownSyntaxSpan.Role?] = Array(repeating: nil, count: length)
        for span in spans where span.range.length > 0 && span.range.location >= 0 &&
            NSMaxRange(span.range) <= length {
            for index in span.range.location..<NSMaxRange(span.range) { roles[index] = span.role }
        }
        var runs: [(range: NSRange, role: MarkdownSyntaxSpan.Role?)] = []
        var start = 0
        for index in 1...length where index == length || roles[index] != roles[start] {
            runs.append((NSRange(location: start, length: index - start), roles[start]))
            start = index
        }
        return runs
    }

    /// 構文色を一時属性として反映する。現在の色と異なる区間だけを変更し、
    /// 変更のない区間の再描画を発生させない。
    @MainActor
    static func apply(to textView: NSTextView, spans providedSpans: [MarkdownSyntaxSpan]? = nil) {
        guard !textView.hasMarkedText(), let layoutManager = textView.layoutManager,
              let length = textView.textStorage?.length, length > 0 else { return }
        let desired = coloredRuns(providedSpans ?? spans(in: textView.string), length: length)
        for run in desired {
            let wanted = run.role.map(color(for:))
            var position = run.range.location
            let runEnd = NSMaxRange(run.range)
            while position < runEnd {
                var effective = NSRange(location: 0, length: 0)
                let current = layoutManager.temporaryAttribute(
                    .foregroundColor, atCharacterIndex: position, longestEffectiveRange: &effective,
                    in: NSRange(location: position, length: runEnd - position)) as? NSColor
                let end = max(position + 1, min(NSMaxRange(effective), runEnd))
                let range = NSRange(location: position, length: end - position)
                if current != wanted {
                    if let wanted {
                        layoutManager.addTemporaryAttribute(.foregroundColor, value: wanted,
                                                            forCharacterRange: range)
                    } else {
                        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                    }
                }
                position = end
            }
        }
    }

    @MainActor
    private static func color(for role: MarkdownSyntaxSpan.Role) -> NSColor {
        switch role {
        case .heading: .systemBlue
        case .code: .systemPurple
        case .link: .linkColor
        case .marker: .secondaryLabelColor
        case .quoteMarker: .systemTeal
        case .listMarker: .systemOrange
        case .taskMarker: .systemGreen
        case .tableMarker: .systemIndigo
        case .codeToken(let token): CodeSyntaxPalette.color(for: token)
        }
    }

    private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
        var cursor = location - 1
        while cursor >= 0 && source.character(at: cursor) == 92 { cursor -= 1 }
        return (location - cursor - 1) % 2 == 1
    }
}
