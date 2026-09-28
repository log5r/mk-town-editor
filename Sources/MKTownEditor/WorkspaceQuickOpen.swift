import Foundation

struct WorkspaceQuickOpenResult: Identifiable, Equatable {
    let url: URL
    let relativePath: String
    let score: Int

    var id: URL { url }
}

enum WorkspaceQuickOpen {
    static func search(nodes: [WorkspaceNode], root: URL, query: String,
                       limit: Int = 50) -> [WorkspaceQuickOpenResult] {
        let terms = query.split(whereSeparator: \.isWhitespace).map { normalized(String($0)) }
        var results: [WorkspaceQuickOpenResult] = []

        func visit(_ nodes: [WorkspaceNode]) {
            for node in nodes {
                if let children = node.children {
                    visit(children)
                } else if node.isEditableDocument {
                    let path = String(node.url.path.dropFirst(root.path.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    let normalizedPath = normalized(path)
                    let name = normalized(node.name)
                    var score = 0
                    var matches = true
                    for term in terms {
                        guard let termScore = fuzzyScore(term, in: normalizedPath) else {
                            matches = false
                            break
                        }
                        score += termScore
                        if name.contains(term) { score += 50 }
                    }
                    if matches {
                        score -= path.count / 10
                        results.append(WorkspaceQuickOpenResult(url: node.url,
                                                                 relativePath: path, score: score))
                    }
                }
            }
        }
        visit(nodes)
        return Array(results.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }.prefix(max(0, limit)))
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func fuzzyScore(_ needle: String, in haystack: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        let characters = Array(haystack)
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
