import Foundation

/// A deliberately small definition-list dialect: `Term` followed by one or more `: Definition` lines.
struct MarkdownDefinitionList: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let term: String
        let definitions: [String]
    }

    let entries: [Entry]

    init?(_ block: MarkdownBlock, dialect: MarkdownDialect) {
        guard dialect == .extended, block.kind == .paragraph else { return nil }
        let lines = block.content.components(separatedBy: "\n")
        var parsed: [Entry] = []
        var index = 0
        while index < lines.count {
            let term = lines[index]
            guard !term.isEmpty, term == term.trimmingCharacters(in: .whitespaces),
                  !term.hasPrefix(":"), index + 1 < lines.count else { return nil }
            index += 1
            var definitions: [String] = []
            while index < lines.count, lines[index].hasPrefix(": ") {
                var description = String(lines[index].dropFirst(2))
                guard !description.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                index += 1
                while index < lines.count,
                      lines[index].hasPrefix("  "),
                      !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    description += "\n" + String(lines[index].dropFirst(2))
                    index += 1
                }
                definitions.append(description)
            }
            guard !definitions.isEmpty else { return nil }
            parsed.append(Entry(term: term, definitions: definitions))
        }
        entries = parsed
    }
}
