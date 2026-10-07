import Foundation

struct WorkspaceQuickOpenResult: Identifiable, Equatable {
    let url: URL
    let relativePath: String
    let score: Int

    var id: URL { url }
}

/// クイックオープン用に、書類の相対パスと正規化済みの名前を一度だけ求めて保持する。
/// 検索語が変わるたびに全書類のパスを正規化し直さないために使う。
struct WorkspaceQuickOpenIndex: Equatable {
    fileprivate struct Entry: Equatable {
        let url: URL
        let relativePath: String
        let normalizedName: String
        let pathCharacters: [Character]
    }

    static let empty = WorkspaceQuickOpenIndex(nodes: [], root: URL(fileURLWithPath: "/"))

    fileprivate let entries: [Entry]
    /// 検索語なしの順位で並べた全書類。シートの書類一覧として使う。
    let rankedDocumentURLs: [URL]

    init(nodes: [WorkspaceNode], root: URL) {
        var entries: [Entry] = []
        func visit(_ nodes: [WorkspaceNode]) {
            for node in nodes {
                if let children = node.children {
                    visit(children)
                } else if node.isEditableDocument {
                    let path = String(node.url.path.dropFirst(root.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    entries.append(Entry(url: node.url, relativePath: path,
                                         normalizedName: WorkspaceQuickOpen.normalized(node.name),
                                         pathCharacters: Array(WorkspaceQuickOpen.normalized(path))))
                }
            }
        }
        visit(nodes)
        self.entries = entries
        rankedDocumentURLs = Self.rank(entries, query: "", limit: .max).map(\.url)
    }

    var documentCount: Int { entries.count }

    func search(_ query: String, limit: Int = 50) -> [WorkspaceQuickOpenResult] {
        Self.rank(entries, query: query, limit: limit)
    }

    private static func rank(_ entries: [Entry], query: String, limit: Int) -> [WorkspaceQuickOpenResult] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { WorkspaceQuickOpen.normalized(String($0)) }
        var results: [WorkspaceQuickOpenResult] = []
        for entry in entries {
            var score = 0
            var matches = true
            for term in terms {
                guard let termScore = WorkspaceQuickOpen.fuzzyScore(term, in: entry.pathCharacters) else {
                    matches = false
                    break
                }
                score += termScore
                if entry.normalizedName.contains(term) { score += 50 }
            }
            if matches {
                score -= entry.relativePath.count / 10
                results.append(WorkspaceQuickOpenResult(url: entry.url, relativePath: entry.relativePath,
                                                        score: score))
            }
        }
        return Array(results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }.prefix(max(0, limit)))
    }
}

enum WorkspaceQuickOpen {
    static func search(nodes: [WorkspaceNode], root: URL, query: String,
                       limit: Int = 50) -> [WorkspaceQuickOpenResult] {
        WorkspaceQuickOpenIndex(nodes: nodes, root: root).search(query, limit: limit)
    }

    fileprivate static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    fileprivate static func fuzzyScore(_ needle: String, in characters: [Character]) -> Int? {
        guard !needle.isEmpty else { return 0 }
        var position = 0
        var previous = -2
        var score = 0
        for character in needle {
            guard let match = characters[position...].firstIndex(of: character) else { return nil }
            score += match == previous + 1 ? 8 : 1
            if match == 0 || "/_- .".contains(characters[match - 1]) { score += 8 }
            previous = match
            position = match + 1
        }
        return score - (characters.count - needle.count) / 8
    }
}
