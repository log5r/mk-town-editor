import Foundation

struct MarkdownHeadingAnchor: Equatable {
    let slug: String
    let entry: MarkdownOutlineEntry
}

struct MarkdownHeadingIndex {
    let anchors: [MarkdownHeadingAnchor]

    init(analysis: MarkdownAnalysis) {
        var used = Set<String>()
        var result: [MarkdownHeadingAnchor] = []
        for entry in MarkdownOutline.entries(in: analysis) {
            let base = Self.slug(for: Self.visibleText(entry.title))
            var slug = base
            var suffix = 1
            while used.contains(slug) {
                slug = "\(base)-\(suffix)"
                suffix += 1
            }
            used.insert(slug)
            result.append(MarkdownHeadingAnchor(slug: slug, entry: entry))
        }
        anchors = result
    }

    func entry(forFragment fragment: String) -> MarkdownOutlineEntry? {
        let decoded = (fragment.removingPercentEncoding ?? fragment)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .lowercased()
        return anchors.first(where: { $0.slug == decoded })?.entry
    }

    static func localFragment(in url: URL) -> String? {
        guard url.scheme == nil, url.host == nil, url.path.isEmpty,
              let fragment = url.fragment, !fragment.isEmpty else { return nil }
        return fragment
    }

    static func slug(for heading: String) -> String {
        let text = heading.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar == " " {
                result.append("-")
            } else if scalar == "-" || scalar == "_" {
                result.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                        CharacterSet.punctuationCharacters.contains(scalar) ||
                        CharacterSet.symbols.contains(scalar) {
                continue
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result.isEmpty ? "section" : result
    }

    private static func visibleText(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options))
            .map { String($0.characters) } ?? markdown
    }
}
