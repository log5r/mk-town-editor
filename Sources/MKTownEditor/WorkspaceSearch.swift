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
        case .all: "すべて"
        case .headings: "見出し"
        case .body: "本文・リスト・引用・表"
        case .code: "コードブロック"
        }
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

enum WorkspaceSearch {
    static func search(root: URL, options: WorkspaceSearchOptions,
                       maximumResults: Int = 2_000) throws -> [WorkspaceSearchResult] {
        guard !options.query.isEmpty else { return [] }
        let scan = WorkspaceFileIndex.scan(root: root)
        guard !scan.isTruncated else { throw WorkspaceFileOperationError.indexTruncated }
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
            let data = try Data(contentsOf: url)
            let text = try MarkdownDocument.decode(data)
            let source = text as NSString
            let lineIndex = MarkdownLineIndex(text)
            let analysis = options.scope == .all ? nil : MarkdownAnalysis(text)
            let searchOptions: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            var start = 0
            while start <= source.length - (options.query as NSString).length {
                try Task.checkCancellation()
                let found = source.range(of: options.query, options: searchOptions,
                                         range: NSRange(location: start, length: source.length - start))
                if found.location == NSNotFound { break }
                start = found.location + max(found.length, 1)
                if let analysis, !options.scope.includes(found, in: analysis) { continue }
                let line = lineIndex.line(containingUTF16Offset: found.location)
                let lineStart = lineIndex.starts[line - 1]
                let lineEnd = line < lineIndex.lineCount ? lineIndex.starts[line] - 1 : source.length
                let excerpt = source.substring(with: NSRange(location: lineStart,
                                                              length: max(0, lineEnd - lineStart)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                results.append(WorkspaceSearchResult(url: url, relativePath: relative,
                                                      line: line, sourceRange: found,
                                                      excerpt: String(excerpt.prefix(240))))
                if results.count >= maximumResults { return results }
            }
        }
        return results
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
