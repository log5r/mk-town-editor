import Foundation

struct ReplacementRule: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var pattern = ""
    var replacement = ""
    var usesRegularExpression = false
    var caseSensitive = false
    var isEnabled = true
    var notes = ""
}

struct ReplacementSet: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var rules: [ReplacementRule] = []

    func duplicated(named name: String) -> Self {
        Self(name: name, rules: rules.map { rule in
            var copy = rule
            copy.id = UUID()
            return copy
        })
    }

    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Archive(version: 1, set: self))
    }

    static func fromJSON(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(ArchiveHeader.self, from: data) else {
            throw ReplacementSetError.invalidArchive
        }
        guard header.version == 1 else { throw ReplacementSetError.unsupportedVersion }
        guard let archive = try? decoder.decode(Archive.self, from: data) else {
            throw ReplacementSetError.invalidArchive
        }
        return archive.set.duplicated(named: archive.set.name)
    }

    static func fromTSV(_ data: Data, named name: String) throws -> Self {
        let payload = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        guard let text = MarkdownTextFormat.decodeUTF8Payload(payload) else {
            throw ReplacementSetError.invalidUTF8
        }
        let lines = MarkdownTextFormat.normalizedText(text).components(separatedBy: "\n")
        var rules: [ReplacementRule] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let fields = line.components(separatedBy: "\t")
            guard fields.count == 2, !fields[0].isEmpty else {
                throw ReplacementSetError.invalidTSVLine(index + 1)
            }
            rules.append(ReplacementRule(pattern: fields[0], replacement: fields[1]))
        }
        guard !rules.isEmpty else { throw ReplacementSetError.noImportedRules }
        return Self(name: name, rules: rules)
    }

    func plan(in source: String, selection: NSRange? = nil, excludesCode: Bool = false,
              dialect: MarkdownDialect = .extended) throws -> ReplacementSetPlan {
        var scope = try Self.validScope(selection, in: source)
        var result = source
        var matchCount = 0
        var diff = ""
        var protected: IndexSet?
        var unchangedPrefix = source.utf16.count
        var unchangedSuffix = unchangedPrefix
        for (index, rule) in rules.enumerated() where rule.isEnabled {
            try Task.checkCancellation()
            let before = result as NSString
            if excludesCode && protected == nil { protected = try Self.codeOffsets(in: result, dialect: dialect) }
            let matches = try rule.matches(in: result, scope: scope, excluding: protected, index: index)
            var updated = ""
            var cursor = 0
            var lines: MarkdownLineIndex?
            var lastDiffLine = 0
            let literal = MarkdownTextFormat.normalizedText(rule.replacement)
            for match in matches {
                try Task.checkCancellation()
                let old = before.substring(with: match.range)
                let replacement = try rule.replacement(for: match, in: before, literal: literal, index: index)
                guard !MarkdownTextFormat.identicalText(old, replacement) else { continue }
                matchCount += 1
                unchangedPrefix = min(unchangedPrefix, match.range.location)
                updated += before.substring(with: NSRange(cursor..<match.range.location))
                updated += replacement
                cursor = NSMaxRange(match.range)
                if lines == nil {
                    lines = MarkdownLineIndex(result, through: matches.last.map { NSMaxRange($0.range) } ?? 0)
                }
                let line = lines?.line(containingUTF16Offset: match.range.location) ?? 1
                if line != lastDiffLine {
                    diff += String(localized: "@@ ルール \(index + 1)、行 \(line) @@") + "\n"
                    lastDiffLine = line
                }
                Self.appendDiffLines(old, prefix: "- ", to: &diff)
                Self.appendDiffLines(replacement, prefix: "+ ", to: &diff)
            }
            if lines != nil {
                unchangedSuffix = min(unchangedSuffix, before.length - cursor)
                updated += before.substring(from: cursor)
                scope.length += updated.utf16.count - before.length
                result = updated
                protected = nil
            }
        }
        try Task.checkCancellation()
        return ReplacementSetPlan(source: source, result: result, matchCount: matchCount, diff: diff,
                                  unchangedPrefix: unchangedPrefix, unchangedSuffix: unchangedSuffix)
    }

    func highlights(in source: String, selection: NSRange? = nil, excludesCode: Bool = false,
                    dialect: MarkdownDialect = .extended) throws -> [NSRange] {
        let scope = try Self.validScope(selection, in: source)
        let protected = try excludesCode ? Self.codeOffsets(in: source, dialect: dialect) : nil
        var matches = IndexSet()
        for (index, rule) in rules.enumerated() where rule.isEnabled {
            try Task.checkCancellation()
            for match in try rule.matches(in: source, scope: scope, excluding: protected, index: index) {
                try Task.checkCancellation()
                matches.insert(integersIn: match.range.location..<NSMaxRange(match.range))
            }
        }
        return matches.rangeView.map { NSRange($0) }
    }

    private struct Archive: Codable {
        let version: Int
        let set: ReplacementSet
    }

    private struct ArchiveHeader: Decodable {
        let version: Int
    }

    private static func validScope(_ scope: NSRange?, in source: String) throws -> NSRange {
        let range = try RegexSearch.validScope(scope, in: source)
        let text = source as NSString
        guard text.isReplacementScalarBoundary(range.location),
              text.isReplacementScalarBoundary(NSMaxRange(range)) else { throw RegexSearchError.invalidScope }
        return range
    }

    private static func codeOffsets(in source: String, dialect: MarkdownDialect) throws -> IndexSet {
        let analysis = MarkdownAnalysis(source, dialect: dialect)
        let text = source as NSString
        var offsets = IndexSet()
        func append(_ range: NSRange) {
            offsets.insert(integersIn: range.location..<NSMaxRange(range))
        }
        var inlineScopes = analysis.footnotes.definitionRanges
        for block in analysis.blocks {
            try Task.checkCancellation()
            switch block.kind {
            case .codeBlock:
                append(block.sourceRange)
                if protectsEndInsertion(in: block, text: text) { offsets.insert(text.length) }
            case .paragraph, .heading, .unorderedList, .orderedList:
                inlineScopes.append(block.sourceRange)
            case .table:
                if let table = block.table {
                    inlineScopes += MarkdownTableEditing.cellSourceRanges(
                        in: text, table: table, startingAt: block.sourceRange.location)
                }
            case .quote, .horizontalRule, .blank:
                // The parser reports the blocks inside a quote separately.
                break
            }
        }
        for scope in inlineScopes {
            try Task.checkCancellation()
            // Inline delimiters pair within their own block or table cell.
            let fragment = text.substring(with: scope)
            for range in MarkdownInlineSyntax.codeSpanRanges(in: fragment) {
                append(NSRange(location: scope.location + range.location, length: range.length))
            }
        }
        return offsets
    }

    private static func protectsEndInsertion(in block: MarkdownBlock, text: NSString) -> Bool {
        guard text.length > 0, NSMaxRange(block.sourceRange) == text.length else { return false }
        let lastUnit = text.character(at: text.length - 1)
        // An insertion on the last physical line would change its code or closing delimiter.
        if lastUnit != 10 && lastUnit != 13 { return true }
        guard block.parentID == nil, let marker = block.codeFenceMarker,
              let fenceLength = block.codeFenceLength else { return false }
        var start = 0
        var contentsEnd = 0
        text.getLineStart(&start, end: nil, contentsEnd: &contentsEnd,
                          for: NSRange(location: text.length - 1, length: 1))
        guard start > block.sourceRange.location else { return true }
        let lastLine = text.substring(with: NSRange(start..<contentsEnd))
        let indentation = lastLine.prefix(while: { $0 == " " }).count
        guard indentation <= 3 else { return true }
        let trimmed = lastLine.dropFirst(indentation).trimmingCharacters(in: .whitespaces)
        return trimmed.count < fenceLength || trimmed.contains { $0 != marker }
    }

    private static func appendDiffLines(_ fragment: String, prefix: String, to diff: inout String) {
        guard !fragment.isEmpty else { return }
        for line in MarkdownTextFormat.normalizedText(fragment).components(separatedBy: "\n") {
            diff += prefix + line + "\n"
        }
    }
}

struct ReplacementSetPlan: Sendable {
    let source: String
    let result: String
    let matchCount: Int
    let diff: String
    private let changedRange: NSRange?
    private let replacement: String

    var edit: MarkdownEdit? {
        guard let changedRange else { return nil }
        return MarkdownEdit(range: changedRange, replacement: replacement,
                            selection: NSRange(location: changedRange.location + replacement.utf16.count, length: 0))
    }

    fileprivate init(source: String, result: String, matchCount: Int, diff: String,
                     unchangedPrefix: Int, unchangedSuffix: Int) {
        self.source = source
        self.result = result
        self.matchCount = matchCount
        guard matchCount > 0, !MarkdownTextFormat.identicalText(source, result) else {
            changedRange = nil
            replacement = ""
            self.diff = ""
            return
        }
        // Measure both margins at the actual edits, so deleting the first "a" of "aa"
        // cannot become a deletion of the second one outside the selection.
        changedRange = NSRange(unchangedPrefix..<(source.utf16.count - unchangedSuffix))
        let after = result as NSString
        replacement = after.substring(with: NSRange(unchangedPrefix..<(after.length - unchangedSuffix)))
        self.diff = diff
    }
}

enum ReplacementSetError: Equatable, LocalizedError, Sendable {
    case rule(Int, RegexSearchError)
    case unsupportedVersion
    case invalidArchive
    case invalidUTF8
    case invalidTSVLine(Int)
    case noImportedRules

    var errorDescription: String? {
        switch self {
        case let .rule(index, error): String(localized: "ルール \(index)：\(error.localizedDescription)")
        case .unsupportedVersion: String(localized: "この置換セットの形式には対応していません。")
        case .invalidArchive: String(localized: "置換セットを読み込めませんでした。")
        case .invalidUTF8: String(localized: "タブ区切りのファイルはUTF-8で保存してください。")
        case let .invalidTSVLine(line):
            String(localized: "\(line)行目に検索文字列と置換文字列をタブで区切って入力してください。")
        case .noImportedRules: String(localized: "読み込める置換ルールがありません。")
        }
    }
}

private extension ReplacementRule {
    struct Match {
        let range: NSRange
        var captures: NSTextCheckingResult?
        var captureCount = 0
    }

    func matches(in source: String, scope: NSRange, excluding protected: IndexSet?, index: Int) throws -> [Match] {
        let text = source as NSString
        func canReplace(_ range: NSRange) -> Bool {
            guard text.isReplacementScalarBoundary(range.location),
                  text.isReplacementScalarBoundary(NSMaxRange(range)) else { return false }
            guard let protected else { return true }
            if range.length > 0 { return !protected.intersects(integersIn: range.location..<NSMaxRange(range)) }
            return !protected.contains(range.location)
        }
        do {
            if !usesRegularExpression {
                let ranges = try DocumentSearch.plainRanges(in: source, pattern: pattern,
                    options: DocumentSearchOptions(caseSensitive: caseSensitive), scope: scope)
                return ranges.filter(canReplace).map { Match(range: $0) }
            }
            let regex = try RegexSearch.compile(pattern, caseSensitive: caseSensitive)
            var matches: [Match] = []
            regex.enumerateMatches(in: source, options: .reportProgress, range: scope) { match, _, stop in
                if let match, canReplace(match.range) {
                    matches.append(Match(range: match.range, captures: match, captureCount: regex.numberOfCaptureGroups))
                }
                if Task.isCancelled { stop.pointee = true }
            }
            try Task.checkCancellation()
            return matches
        } catch let error as RegexSearchError {
            throw ReplacementSetError.rule(index + 1, error)
        }
    }

    func replacement(for match: Match, in text: NSString, literal: String, index: Int) throws -> String {
        guard let captures = match.captures else { return literal }
        do {
            let value = try RegexSearch.expand(replacement, for: captures, in: text, captureCount: match.captureCount)
            return MarkdownTextFormat.normalizedText(value)
        } catch let error as RegexSearchError {
            throw ReplacementSetError.rule(index + 1, error)
        }
    }
}

private extension NSString {
    func isReplacementScalarBoundary(_ offset: Int) -> Bool {
        offset == length || !(0xDC00...0xDFFF).contains(character(at: offset))
    }
}
