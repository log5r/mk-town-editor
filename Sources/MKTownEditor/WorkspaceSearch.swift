import Darwin
import Foundation

struct WorkspaceSearchResult: Identifiable, Sendable {
    let url: URL
    let relativePath: String
    let line: Int
    let sourceRange: NSRange
    let excerpt: String

    var id: String { "\(relativePath):\(sourceRange.location):\(sourceRange.length)" }
}

struct WorkspaceSearchOptions: Sendable {
    var query: String
    var includePatterns: [String] = ["*"]
    var excludePatterns: [String] = []
    var caseSensitive = false
    var scope: WorkspaceSearchScope = .all
}

enum WorkspaceSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all
    case headings
    case body
    case code

    var id: Self { self }

    var title: String {
        switch self {
        case .all: String(localized: "すべて")
        case .headings: String(localized: "見出し")
        case .body: String(localized: "本文・リスト・引用・表")
        case .code: String(localized: "コードブロック")
        }
    }

    func includes(_ range: NSRange, in index: WorkspaceSearchScopeIndex) -> Bool {
        guard self != .all else { return true }
        if index.code.contains(range) { return self == .code }
        if index.headings.contains(range) { return self == .headings }
        return self == .body && index.body.contains(range)
    }

    func includes(_ range: NSRange, in analysis: MarkdownAnalysis) -> Bool {
        guard self != .all else { return true }
        let covering = analysis.blocks.filter {
            $0.sourceRange.location <= range.location &&
                NSMaxRange(range) <= NSMaxRange($0.sourceRange)
        }
        if covering.contains(where: { $0.kind == .codeBlock }) { return self == .code }
        if covering.contains(where: {
            if case .heading = $0.kind { return true }
            return false
        }) { return self == .headings }
        return self == .body && covering.contains(where: {
            switch $0.kind {
            case .paragraph, .quote, .unorderedList, .orderedList, .table: true
            default: false
            }
        })
    }
}

/// 構造スコープの判定用に、種類ごとのブロック範囲を位置順に並べたもの。
/// 一致ごとに全ブロックを走査せず、二分探索で包含を判定する。
struct WorkspaceSearchScopeIndex {
    struct Intervals {
        private var ranges: [NSRange] = []

        init(_ ranges: [NSRange]) {
            // ブロックは入れ子か互いに素なので、重なる範囲は外側の範囲にまとめられる。
            for range in ranges.sorted(by: { ($0.location, -$0.length) < ($1.location, -$1.length) }) {
                if let last = self.ranges.last, range.location < NSMaxRange(last) {
                    if NSMaxRange(range) > NSMaxRange(last) {
                        self.ranges[self.ranges.count - 1] = NSUnionRange(last, range)
                    }
                } else {
                    self.ranges.append(range)
                }
            }
        }

        func contains(_ range: NSRange) -> Bool {
            var low = 0
            var high = ranges.count
            while low < high {
                let middle = (low + high) / 2
                if ranges[middle].location <= range.location { low = middle + 1 } else { high = middle }
            }
            guard low > 0 else { return false }
            return NSMaxRange(range) <= NSMaxRange(ranges[low - 1])
        }
    }

    let code: Intervals
    let headings: Intervals
    let body: Intervals

    init(_ analysis: MarkdownAnalysis) {
        var code: [NSRange] = []
        var headings: [NSRange] = []
        var body: [NSRange] = []
        for block in analysis.blocks {
            switch block.kind {
            case .codeBlock: code.append(block.sourceRange)
            case .heading: headings.append(block.sourceRange)
            case .paragraph, .quote, .unorderedList, .orderedList, .table: body.append(block.sourceRange)
            default: break
            }
        }
        self.code = Intervals(code)
        self.headings = Intervals(headings)
        self.body = Intervals(body)
    }
}

struct WorkspaceSearchReport: Sendable {
    let results: [WorkspaceSearchResult]
    let skippedDocuments: [URL]
    let isTruncated: Bool
}

enum WorkspaceSearch {
    static func search(root: URL, options: WorkspaceSearchOptions,
                       maximumResults: Int = 2_000) throws -> [WorkspaceSearchResult] {
        try report(root: root, options: options, maximumResults: maximumResults).results
    }

    static func report(root: URL, options: WorkspaceSearchOptions,
                       maximumResults: Int = 2_000) throws -> WorkspaceSearchReport {
        guard !options.query.isEmpty else { return WorkspaceSearchReport(results: [], skippedDocuments: [], isTruncated: false) }
        let scan = try WorkspaceFileIndex.scan(root: root)
        var skipped: [URL] = []
        var results: [WorkspaceSearchResult] = []
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let files = documentURLs(in: scan.nodes)
        for url in files {
            try Task.checkCancellation()
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(rootPrefix) else { continue }
            let relative = String(path.dropFirst(rootPrefix.count))
            guard matches(relative, patterns: options.includePatterns),
                  !matches(relative, patterns: options.excludePatterns) else { continue }
            guard let data = try? Data(contentsOf: url), let text = try? MarkdownDocument.decode(data) else {
                skipped.append(url)
                continue
            }
            let source = text as NSString
            let lineIndex = MarkdownLineIndex(text)
            let scopeIndex = options.scope == .all ? nil : WorkspaceSearchScopeIndex(MarkdownAnalysis(text))
            let searchOptions: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            var start = 0
            while start <= source.length - (options.query as NSString).length {
                try Task.checkCancellation()
                let found = source.range(of: options.query, options: searchOptions,
                                         range: NSRange(location: start, length: source.length - start))
                if found.location == NSNotFound { break }
                start = found.location + max(found.length, 1)
                if let scopeIndex, !options.scope.includes(found, in: scopeIndex) { continue }
                let line = lineIndex.line(containingUTF16Offset: found.location)
                let lineStart = lineIndex.starts[line - 1]
                let lineEnd = line < lineIndex.lineCount ? lineIndex.starts[line] - 1 : source.length
                let excerpt = source.substring(with: NSRange(location: lineStart,
                                                              length: max(0, lineEnd - lineStart)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(WorkspaceSearchResult(url: url, relativePath: relative,
                                                      line: line, sourceRange: found,
                                                      excerpt: String(excerpt.prefix(240))))
                if results.count >= maximumResults {
                    return WorkspaceSearchReport(results: results, skippedDocuments: skipped, isTruncated: true)
                }
            }
        }
        return WorkspaceSearchReport(results: results, skippedDocuments: skipped, isTruncated: scan.isTruncated)
    }

    private static func documentURLs(in nodes: [WorkspaceNode]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if let children = node.children { return documentURLs(in: children) }
            return node.isEditableDocument ? [node.url] : []
        }
    }

    private static func matches(_ path: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in fnmatch(pattern, path, 0) == 0 }
    }
}
