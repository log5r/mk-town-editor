import CryptoKit
import Foundation

enum WorkspaceReplaceError: LocalizedError {
    case noMatches
    case tooManyMatches
    case documentChanged(URL)
    case documentOpen(URL)
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .noMatches: "置換対象がありません。"
        case .tooManyMatches: "一致が10,000件を超えました。対象パターンを絞ってください。"
        case let .documentChanged(url): "確認後に書類が変更されました: \(url.lastPathComponent)"
        case let .documentOpen(url): "書類が開いています。保存して閉じてから置換してください: \(url.lastPathComponent)"
        case .rollbackFailed: "変更の復元に失敗しました。対象ファイルを確認してください。"
        }
    }
}

struct WorkspaceReplaceChange: Sendable {
    let url: URL
    let relativePath: String
    let originalData: Data
    let updatedData: Data
    let matches: [WorkspaceSearchResult]
    let previews: [WorkspaceReplacePreview]
}

struct WorkspaceReplacePreview: Sendable {
    let line: Int
    let before: String
    let after: String
}

struct WorkspaceReplacePlan: Sendable {
    let changes: [WorkspaceReplaceChange]

    var matchCount: Int { changes.reduce(0) { $0 + $1.matches.count } }

    func apply(selectedURLs: Set<URL>, openDocuments: [URL],
               write: (Data, URL) throws -> Void = { data, url in
                   try data.write(to: url, options: .atomic)
               }) throws {
        let selectedPaths = Set(selectedURLs.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        })
        let selected = changes.filter {
            selectedPaths.contains($0.url.resolvingSymlinksInPath().standardizedFileURL.path)
        }
        guard !selected.isEmpty else { throw WorkspaceReplaceError.noMatches }
        let openPaths = Set(openDocuments.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        })
        for change in selected {
            let path = change.url.resolvingSymlinksInPath().standardizedFileURL.path
            guard !openPaths.contains(path) else { throw WorkspaceReplaceError.documentOpen(change.url) }
            guard let data = try? Data(contentsOf: change.url),
                  Data(SHA256.hash(data: data)) == Data(SHA256.hash(data: change.originalData)) else {
                throw WorkspaceReplaceError.documentChanged(change.url)
            }
        }
        var written: [WorkspaceReplaceChange] = []
        do {
            for change in selected {
                written.append(change)
                try write(change.updatedData, change.url)
            }
        } catch {
            var restored = true
            for change in written.reversed() {
                do { try change.originalData.write(to: change.url, options: .atomic) }
                catch { restored = false }
            }
            if !restored { throw WorkspaceReplaceError.rollbackFailed }
            throw error
        }
    }
}

enum WorkspaceReplace {
    static func plan(root: URL, options: WorkspaceSearchOptions,
                     replacement: String) throws -> WorkspaceReplacePlan {
        let matches = try WorkspaceSearch.search(root: root, options: options,
                                                 maximumResults: 10_001)
        guard !matches.isEmpty else { throw WorkspaceReplaceError.noMatches }
        guard matches.count <= 10_000 else { throw WorkspaceReplaceError.tooManyMatches }
        let grouped = Dictionary(grouping: matches, by: \.url)
        let changes = try grouped.keys.sorted { $0.path < $1.path }.map { url in
            try Task.checkCancellation()
            let entries = grouped[url] ?? []
            let data = try Data(contentsOf: url)
            var document = try MarkdownDocument(data: data)
            let source = document.text as NSString
            let compareOptions: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            for entry in entries {
                guard entry.sourceRange.location + entry.sourceRange.length <= source.length,
                      source.substring(with: entry.sourceRange)
                        .compare(options.query, options: compareOptions) == .orderedSame else {
                    throw WorkspaceReplaceError.documentChanged(url)
                }
            }
            let previews = entries.map { entry in
                let start = max(0, entry.sourceRange.location - 32)
                let end = min(source.length, entry.sourceRange.location + entry.sourceRange.length + 32)
                let before = source.substring(with: NSRange(location: start, length: end - start))
                let after = (before as NSString).replacingCharacters(
                    in: NSRange(location: entry.sourceRange.location - start,
                                length: entry.sourceRange.length), with: replacement)
                return WorkspaceReplacePreview(line: entry.line, before: before, after: after)
            }
            let updated = NSMutableString(string: document.text)
            for entry in entries.sorted(by: { $0.sourceRange.location > $1.sourceRange.location }) {
                updated.replaceCharacters(in: entry.sourceRange, with: replacement)
            }
            document.text = updated as String
            return WorkspaceReplaceChange(url: url, relativePath: entries[0].relativePath,
                                          originalData: data, updatedData: document.encodedData(),
                                          matches: entries, previews: previews)
        }
        return WorkspaceReplacePlan(changes: changes)
    }
}
