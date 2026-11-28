import Foundation

enum DocumentCountUnit: String, CaseIterable, Codable, Sendable {
    case grapheme, unicodeScalar, utf16, bytes
}

enum DocumentCountNormalization: String, CaseIterable, Codable, Sendable {
    case none, nfc, nfd, nfkc, nfkd

    func apply(to text: String) -> String {
        switch self {
        case .none: text
        case .nfc: text.precomposedStringWithCanonicalMapping
        case .nfd: text.decomposedStringWithCanonicalMapping
        case .nfkc: text.decomposedStringWithCompatibilityMapping.precomposedStringWithCanonicalMapping
        case .nfkd: text.decomposedStringWithCompatibilityMapping
        }
    }
}

struct DocumentCountOptions: Codable, Equatable, Sendable {
    var unit: DocumentCountUnit = .grapheme
    var encoding: MarkdownTextEncoding = .utf8
    var normalization: DocumentCountNormalization = .none
    var excludeNewlines = false
    var excludeWhitespace = false
    var collapseWhitespace = false
    var excludeMarkdownSyntax = false
    var excludeLinkDestinations = false
    var excludeCodeBlocks = false
    var excludeFrontMatter = false

    var usesMarkdown: Bool {
        excludeMarkdownSyntax || excludeLinkDestinations || excludeCodeBlocks || excludeFrontMatter
    }

    func count(in source: String, ranges: [NSRange] = [], analysis: MarkdownAnalysis? = nil,
               syntaxSpans: [MarkdownSyntaxSpan]? = nil) -> Int? {
        measure(in: source, ranges: ranges, analysis: analysis, syntaxSpans: syntaxSpans,
                checkCancellation: {})
    }

    func countObservingCancellation(in source: String, ranges: [NSRange] = [],
                                    analysis: MarkdownAnalysis? = nil,
                                    syntaxSpans: [MarkdownSyntaxSpan]? = nil) throws -> Int? {
        try measure(in: source, ranges: ranges, analysis: analysis, syntaxSpans: syntaxSpans,
                    checkCancellation: { try Task.checkCancellation() })
    }

    private func measure<Failure>(in source: String, ranges: [NSRange], analysis: MarkdownAnalysis?,
                                  syntaxSpans: [MarkdownSyntaxSpan]?,
                                  checkCancellation: () throws(Failure) -> Void) throws(Failure) -> Int? {
        try checkCancellation()
        let text = source as NSString
        let scopes = ranges.isEmpty ? [NSRange(location: 0, length: text.length)] : ranges.filter {
            $0.location >= 0 && $0.location < text.length &&
            $0.length > 0 && $0.length <= text.length - $0.location &&
            Self.isScalarBoundary($0.location, in: text) && Self.isScalarBoundary(NSMaxRange($0), in: text)
        }
        let exclusions = usesMarkdown ? try markdownExclusions(
            in: source, scopes: scopes, analysis: analysis ?? MarkdownAnalysis(source),
            syntaxSpans: syntaxSpans, checkCancellation: checkCancellation) : IndexSet()
        var total = 0
        for range in scopes {
            try checkCancellation()
            let filtered: String
            if ranges.isEmpty && exclusions.isEmpty {
                filtered = source
            } else {
                var value = ""
                var cursor = range.location
                for exclusion in exclusions.rangeView(of: range.location..<NSMaxRange(range)) {
                    try checkCancellation()
                    value += text.substring(with: NSRange(cursor..<exclusion.lowerBound))
                    cursor = exclusion.upperBound
                }
                value += text.substring(with: NSRange(cursor..<NSMaxRange(range)))
                filtered = value
            }
            let normalized = normalization.apply(to: filtered)
            let transformed = try applyingWhitespaceOptions(to: normalized, checkCancellation: checkCancellation)
            guard let amount = try amount(in: transformed, checkCancellation: checkCancellation) else { return nil }
            total += amount
        }
        return total
    }

    private static func isScalarBoundary(_ offset: Int, in text: NSString) -> Bool {
        offset == text.length || !(0xDC00...0xDFFF).contains(text.character(at: offset))
    }

    private func applyingWhitespaceOptions<Failure>(
        to text: String, checkCancellation: () throws(Failure) -> Void
    ) throws(Failure) -> String {
        guard excludeNewlines || excludeWhitespace || collapseWhitespace else { return text }
        var result = ""
        var inWhitespace = false
        for (index, character) in text.enumerated() {
            if index.isMultiple(of: DocumentStatistics.cancellationCheckInterval) { try checkCancellation() }
            if character.isNewline {
                if !excludeNewlines {
                    result.append(character)
                    inWhitespace = false
                }
            } else if character.isWhitespace {
                if !excludeWhitespace && (!collapseWhitespace || !inWhitespace) {
                    result.append(collapseWhitespace ? " " : character)
                }
                inWhitespace = true
            } else {
                result.append(character)
                inWhitespace = false
            }
        }
        return result
    }

    private func amount<Failure>(in text: String,
                                 checkCancellation: () throws(Failure) -> Void) throws(Failure) -> Int? {
        try checkCancellation()
        switch unit {
        case .grapheme:
            // Use the cancellable pass for very long documents.
            var count = 0
            for _ in text {
                count += 1
                if count.isMultiple(of: DocumentStatistics.cancellationCheckInterval) { try checkCancellation() }
            }
            return count
        case .unicodeScalar:
            return text.unicodeScalars.count
        case .utf16:
            return text.utf16.count
        case .bytes:
            if text.isEmpty { return 0 }
            switch encoding {
            case .utf8: return text.utf8.count
            case .utf16LE, .utf16BE: return text.utf16.count * 2
            default: return (try? MarkdownEncodingConverter.encode(text, as: encoding))?.count
            }
        }
    }
}

extension DocumentCountOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        unit = (try? values.decode(DocumentCountUnit.self, forKey: .unit)) ?? unit
        encoding = (try? values.decode(MarkdownTextEncoding.self, forKey: .encoding)) ?? encoding
        normalization = (try? values.decode(DocumentCountNormalization.self, forKey: .normalization)) ?? normalization
        excludeNewlines = (try? values.decode(Bool.self, forKey: .excludeNewlines)) ?? excludeNewlines
        excludeWhitespace = (try? values.decode(Bool.self, forKey: .excludeWhitespace)) ?? excludeWhitespace
        collapseWhitespace = (try? values.decode(Bool.self, forKey: .collapseWhitespace)) ?? collapseWhitespace
        excludeMarkdownSyntax = (try? values.decode(Bool.self, forKey: .excludeMarkdownSyntax)) ?? excludeMarkdownSyntax
        excludeLinkDestinations = (try? values.decode(Bool.self, forKey: .excludeLinkDestinations)) ?? excludeLinkDestinations
        excludeCodeBlocks = (try? values.decode(Bool.self, forKey: .excludeCodeBlocks)) ?? excludeCodeBlocks
        excludeFrontMatter = (try? values.decode(Bool.self, forKey: .excludeFrontMatter)) ?? excludeFrontMatter
    }
}

private extension DocumentCountOptions {
    static let headingOpening = try! NSRegularExpression(pattern: #"^(?:[ \t]*>[ \t]?)* {0,3}(#{1,6})(?=[ \t]|$)"#)
    static let headingClosing = try! NSRegularExpression(pattern: #"[ \t](#+)[ \t]*$"#)
    static let reference = try! NSRegularExpression(
        pattern: #"\[((?:\\.|[^\\\]\r\n])+)](?:\[((?:\\.|[^\\\]\r\n])*)])?"#)
    static let referenceDefinition = try! NSRegularExpression(
        pattern: #"^(?:[ \t]*>[ \t]?)* {0,3}\[[^\]]+\]:[ \t]*(?:<([^<>]*)>|([^\s]+))"#)
    static let automaticLink = try! NSRegularExpression(
        pattern: #"<([A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]+|[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)>"#)
    static let inlineHTML = try! NSRegularExpression(
        pattern: #"<(mark|sup|sub)>([^<>\r\n]+)</\1>"#, options: .caseInsensitive)
    static let escapedPunctuation = try! NSRegularExpression(
        pattern: #"\\(?:[\x21-\x2F\x3A-\x40\x5B-\x60\x7B-\x7E]|(?=\r?\n))"#)

    func markdownExclusions<Failure>(
        in source: String, scopes: [NSRange], analysis: MarkdownAnalysis, syntaxSpans: [MarkdownSyntaxSpan]?,
        checkCancellation: () throws(Failure) -> Void
    ) throws(Failure) -> IndexSet {
        var result = IndexSet()
        var literal = IndexSet()
        let text = source as NSString
        if let frontMatter = analysis.frontMatter {
            literal.add(frontMatter.sourceRange)
            if excludeFrontMatter { result = literal }
        }

        func isInScope(_ candidate: NSRange) -> Bool {
            scopes.contains { NSIntersectionRange($0, candidate).length > 0 }
        }

        var inlineScopes: [NSRange] = analysis.footnotes.definitionRanges.filter(isInScope)
        for (index, block) in analysis.blocks.enumerated() {
            if index.isMultiple(of: DocumentStatistics.cancellationCheckInterval) { try checkCancellation() }
            guard isInScope(block.sourceRange) else { continue }
            switch block.kind {
            case .codeBlock:
                literal.add(block.sourceRange)
                if excludeCodeBlocks {
                    result.add(block.sourceRange)
                } else if excludeMarkdownSyntax, let marker = block.codeFenceMarker,
                          let length = block.codeFenceLength {
                    result.add(contentLine(in: text, at: block.sourceRange.location))
                    let end = contentLine(in: text, at: NSMaxRange(block.sourceRange) - 1)
                    if end.location != block.sourceRange.location {
                        let line = text.substring(with: end)
                        let fence = line.replacingOccurrences(of: #"^(?:[ \t]*>[ \t]?)* {0,3}"#,
                                                               with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespaces)
                        if fence.count >= length, fence.allSatisfy({ $0 == marker }) {
                            result.add(end)
                        }
                    }
                }
            case .heading:
                inlineScopes.append(block.sourceRange)
                if excludeMarkdownSyntax {
                    let start = contentLine(in: text, at: block.sourceRange.location)
                    if let opening = Self.headingOpening.firstMatch(in: source, range: start) {
                        result.add(opening.range(at: 1))
                        if let closing = Self.headingClosing.firstMatch(in: source, range: start) {
                            result.add(closing.range(at: 1))
                        }
                    } else {
                        result.add(contentLine(in: text, at: NSMaxRange(block.sourceRange) - 1))
                    }
                }
            case .horizontalRule:
                if excludeMarkdownSyntax { result.add(contentLine(in: text, at: block.sourceRange.location)) }
            case .table:
                guard let table = block.table else { break }
                inlineScopes += MarkdownTableEditing.cellSourceRanges(
                    in: text, table: table, startingAt: block.sourceRange.location).filter(isInScope)
                if excludeMarkdownSyntax {
                    let firstLine = text.lineRange(for: NSRange(location: block.sourceRange.location, length: 0))
                    result.add(contentLine(in: text, at: NSMaxRange(firstLine)))
                }
            case .paragraph, .unorderedList, .orderedList:
                inlineScopes.append(block.sourceRange)
            case .blank, .quote:
                break
            }
        }

        guard excludeMarkdownSyntax || excludeLinkDestinations else { return result }

        for definition in analysis.references.values where isInScope(definition.sourceRange) {
            try checkCancellation()
            let line = contentLine(in: text, at: definition.sourceRange.location)
            guard let match = Self.referenceDefinition.firstMatch(in: source, range: line) else { continue }
            let destination = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
            excludeLink(in: line, preserving: destination, result: &result)
        }

        for scope in inlineScopes where scope.length > 0 {
            try checkCancellation()
            let inline = text.substring(with: scope)
            let inlineText = inline as NSString
            let code = MarkdownInlineSyntax.codeSpanRanges(in: inline)
            for range in code {
                let absolute = range.offset(by: scope.location)
                literal.add(absolute)
                if excludeMarkdownSyntax {
                    var opening = 0
                    while range.location + opening < inlineText.length,
                          inlineText.character(at: range.location + opening) == 96 {
                        opening += 1
                    }
                    if opening > 0 {
                        result.add(NSRange(location: absolute.location, length: opening))
                        result.add(NSRange(location: NSMaxRange(absolute) - opening, length: opening))
                    }
                }
            }
            try excludeInlineLinks(in: inline, scope: scope, literal: &literal, result: &result,
                                   analysis: analysis, checkCancellation: checkCancellation)
            if excludeMarkdownSyntax, analysis.dialect == .extended {
                for match in Self.inlineHTML.matches(in: source, range: scope)
                where !literal.contains(match.range.location) &&
                      !MarkdownLinkSyntax.isEscaped(text, at: match.range.location) {
                    let label = match.range(at: 2)
                    result.add(NSRange(match.range.location..<label.location))
                    result.add(NSRange(NSMaxRange(label)..<NSMaxRange(match.range)))
                }
            }
            if excludeMarkdownSyntax {
                for match in Self.escapedPunctuation.matches(in: source, range: scope)
                where !literal.contains(match.range.location) {
                    result.insert(match.range.location)
                }
                try excludeEmphasis(in: inline, scope: scope, literal: literal, result: &result,
                                    checkCancellation: checkCancellation)
            }
        }
        if excludeMarkdownSyntax {
            let spans = syntaxSpans ?? MarkdownSyntaxHighlighter.spans(in: source, analysis: analysis)
            for (index, span) in spans.enumerated() {
                if index.isMultiple(of: DocumentStatistics.cancellationCheckInterval) { try checkCancellation() }
                guard span.range.length > 0, !literal.contains(span.range.location), isInScope(span.range) else {
                    continue
                }
                switch span.role {
                case .quoteMarker:
                    // The highlighter includes spaces in the colored span.
                    for offset in span.range.location..<NSMaxRange(span.range) where text.character(at: offset) == 62 {
                        result.insert(offset)
                    }
                case .tableMarker:
                    if !MarkdownLinkSyntax.isEscaped(text, at: span.range.location) { result.add(span.range) }
                case .listMarker, .taskMarker:
                    result.add(span.range)
                default:
                    break
                }
            }
        }
        return result
    }

    func excludeEmphasis<Failure>(
        in inline: String, scope: NSRange, literal: IndexSet, result: inout IndexSet,
        checkCancellation: () throws(Failure) -> Void
    ) throws(Failure) {
        guard inline.utf8.contains(where: { $0 == 42 || $0 == 95 || $0 == 126 }) else { return }
        // Foundation parses CRLF as LF but reports source offsets as if it read an LF buffer.
        // Parse that buffer explicitly and translate the surviving ranges to the original text.
        let parsingSource = MarkdownTextFormat.normalizedText(inline)
        let original = inline as NSString
        let normalized = parsingSource as NSString
        var removedCRs: [Int] = []
        if original.length != normalized.length {
            for (offset, character) in inline.utf16.enumerated()
            where character == 13 && offset + 1 < original.length && original.character(at: offset + 1) == 10 {
                removedCRs.append(offset - removedCRs.count)
            }
        }
        func originalOffset(_ offset: Int) -> Int {
            var low = 0
            var high = removedCRs.count
            while low < high {
                let middle = (low + high) / 2
                if removedCRs[middle] < offset { low = middle + 1 }
                else { high = middle }
            }
            return offset + low
        }
        guard let parsed = try? AttributedString(markdown: parsingSource, options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                appliesSourcePositionAttributes: true)) else { return }

        let intents: InlinePresentationIntent = [.emphasized, .stronglyEmphasized, .strikethrough]
        var visible = IndexSet()
        var containsEmphasis = false
        for run in parsed.runs {
            try checkCancellation()
            guard let position = run.markdownSourcePosition,
                  let range = Range(position, in: parsingSource) else { return }
            if let intent = run.inlinePresentationIntent, !intent.intersection(intents).isEmpty {
                containsEmphasis = true
            }
            var offsets = NSRange(range, in: parsingSource)
            let rendered = String(parsed[run.range].characters)
            let renderedLength = rendered.utf16.count
            // A literal delimiter left over after an emphasis run can share the source position
            // of the whole delimiter. Its visible characters are the trailing suffix.
            let prefixLength = offsets.length - renderedLength
            if prefixLength > 0, normalized.substring(with: offsets).hasSuffix(rendered) {
                let prefixEnd = offsets.location + prefixLength
                if (offsets.location..<prefixEnd).allSatisfy({
                    let unit = normalized.character(at: $0)
                    return unit == 42 || unit == 95 || unit == 126
                }) {
                    offsets = NSRange(location: prefixEnd, length: renderedLength)
                }
            }
            visible.insert(integersIn: originalOffset(offsets.location)..<originalOffset(NSMaxRange(offsets)))
        }
        guard containsEmphasis else { return }
        // Keep original whitespace and Unicode. Only remove delimiters outside the parser's
        // visible source ranges, leaving matched links and code to their own filters.
        var gaps = IndexSet(integersIn: 0..<original.length)
        gaps.subtract(visible)
        for gap in gaps.rangeView {
            try checkCancellation()
            for offset in gap {
                if offset.isMultiple(of: DocumentStatistics.cancellationCheckInterval) {
                    try checkCancellation()
                }
                let unit = original.character(at: offset)
                if (unit == 42 || unit == 95 || unit == 126),
                   !literal.contains(scope.location + offset),
                   !MarkdownLinkSyntax.isEscaped(original, at: offset) {
                    result.insert(scope.location + offset)
                }
            }
        }
    }

    func excludeInlineLinks<Failure>(
        in inline: String, scope: NSRange, literal: inout IndexSet, result: inout IndexSet,
        analysis: MarkdownAnalysis, checkCancellation: () throws(Failure) -> Void
    ) throws(Failure) {
        var pending = [(inline, scope)]
        while let (inline, scope) = pending.popLast() {
            try checkCancellation()
            let text = inline as NSString
            let full = NSRange(location: 0, length: text.length)
            var matchedLinks = IndexSet()
            for link in MarkdownLinkSyntax.inlineLinks(in: inline) {
                try checkCancellation()
                let range = link.range.offset(by: scope.location)
                guard !literal.contains(range.location) else { continue }
                let label = link.labelRange.offset(by: scope.location)
                let destination = link.destinationRange.offset(by: scope.location)
                matchedLinks.add(link.range)
                literal.add(NSRange(NSMaxRange(label)..<NSMaxRange(range)))
                if excludeMarkdownSyntax { result.add(NSRange(range.location..<label.location)) }
                excludeLink(in: NSRange(NSMaxRange(label)..<NSMaxRange(range)),
                            preserving: destination, result: &result)
                // A linked image contributes its label and its own destination.
                let labelText = text.substring(with: link.labelRange)
                if labelText.contains("[") {
                    pending.append((labelText, label))
                }
            }
            for match in Self.automaticLink.matches(in: inline, range: full) {
                let range = match.range.offset(by: scope.location)
                guard !literal.contains(range.location), !matchedLinks.contains(match.range.location),
                      !MarkdownLinkSyntax.isEscaped(text, at: match.range.location) else { continue }
                literal.add(range)
                excludeLink(in: range, preserving: match.range(at: 1).offset(by: scope.location), result: &result)
            }
            guard excludeMarkdownSyntax, !analysis.references.isEmpty else { continue }
            for match in Self.reference.matches(in: inline, range: full) {
                let label = match.range(at: 1)
                let identifier = match.range(at: 2)
                let location = scope.location + match.range.location
                let end = NSMaxRange(match.range)
                guard !literal.contains(location), !matchedLinks.contains(match.range.location),
                      !MarkdownLinkSyntax.isEscaped(text, at: match.range.location),
                      end == text.length || ![40, 58].contains(text.character(at: end)) else { continue }
                let key = text.substring(with: identifier.location != NSNotFound && identifier.length > 0 ? identifier : label)
                guard analysis.references[MarkdownAnalysis.normalizedReferenceLabel(key)] != nil else { continue }
                let image = match.range.location > 0 && text.character(at: match.range.location - 1) == 33 &&
                    !MarkdownLinkSyntax.isEscaped(text, at: match.range.location - 1)
                result.add(NSRange((image ? location - 1 : location)..<(scope.location + label.location)))
                result.add(NSRange((scope.location + NSMaxRange(label))..<(scope.location + end)))
            }
        }
    }

    func excludeLink(in range: NSRange, preserving destination: NSRange, result: inout IndexSet) {
        if excludeLinkDestinations {
            result.add(excludeMarkdownSyntax ? range : destination)
        } else if excludeMarkdownSyntax {
            result.add(NSRange(range.location..<destination.location))
            result.add(NSRange(NSMaxRange(destination)..<NSMaxRange(range)))
        }
    }

    func contentLine(in source: NSString, at offset: Int) -> NSRange {
        var start = 0
        var end = 0
        source.getLineStart(&start, end: nil, contentsEnd: &end,
                            for: NSRange(location: offset, length: 0))
        return NSRange(start..<end)
    }
}

private extension NSRange {
    func offset(by distance: Int) -> NSRange {
        NSRange(location: location + distance, length: length)
    }
}

private extension IndexSet {
    mutating func add(_ range: NSRange) {
        if let offsets = Range(range), !offsets.isEmpty { insert(integersIn: offsets) }
    }
}
