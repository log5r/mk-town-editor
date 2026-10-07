import Foundation

struct WorkspaceEmbedReference: Hashable, Sendable {
    let target: String
    let section: String?
}

struct WorkspaceEmbedExpansion: Equatable, Sendable {
    let text: String
    let issues: [String]
}

struct WorkspaceEmbedLink: Equatable {
    let targetRange: NSRange
    let target: String
}

enum WorkspaceDocumentEmbed {
    static let maximumDepth = 4
    static let maximumBytes = 1_000_000

    static func reference(in line: String) -> WorkspaceEmbedReference? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("![["), trimmed.hasSuffix("]]"),
              !trimmed.contains("\n") else { return nil }
        let raw = String(trimmed.dropFirst(3).dropLast(2))
        let pieces = raw.split(separator: "#", maxSplits: 1,
            omittingEmptySubsequences: false)
        let target = String(pieces[0]).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.contains("|"),
              !target.contains("[["), !target.contains("]]"),
              !target.contains("\\") else { return nil }
        let section = pieces.count == 2 ? String(pieces[1]) : nil
        if let section, section.isEmpty { return nil }
        return WorkspaceEmbedReference(target: target, section: section)
    }

    static func links(in source: String, analysis: MarkdownAnalysis? = nil) -> [WorkspaceEmbedLink] {
        let analysis = analysis ?? MarkdownAnalysis(source)
        let excluded = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
            + (analysis.frontMatter.map { [$0.sourceRange] } ?? [])
        let text = source as NSString
        let lines = MarkdownLineIndex(source)
        return lines.starts.compactMap { start in
            guard !excluded.contains(where: { NSLocationInRange(start, $0) }) else { return nil }
            let lineIndex = lines.line(containingUTF16Offset: start)
            let end = lineIndex < lines.lineCount ? lines.starts[lineIndex] : text.length
            let line = text.substring(with: NSRange(location: start, length: end - start))
            guard let parsed = reference(in: line),
                  let marker = line.range(of: "![["),
                  let closing = line.range(of: "]]", options: .backwards) else { return nil }
            let prefix = line[..<marker.lowerBound]
            let inside = String(line[marker.upperBound..<closing.lowerBound])
            let rawTarget = String(inside.split(separator: "#", maxSplits: 1,
                omittingEmptySubsequences: false)[0])
            return WorkspaceEmbedLink(targetRange: NSRange(
                location: start + (prefix as NSString).length + 3,
                length: (rawTarget as NSString).length), target: parsed.target)
        }
    }

    static func expand(_ reference: WorkspaceEmbedReference, from documentURL: URL,
                       documents: [URL], load: (URL) -> String?) -> WorkspaceEmbedExpansion {
        expand(reference, from: documentURL, index: WorkspaceDocumentIndex(documents: documents), load: load,
            ancestors: [documentURL.resolvingSymlinksInPath().standardizedFileURL], depth: 0)
    }

    private static func expand(_ reference: WorkspaceEmbedReference, from documentURL: URL,
                               index: WorkspaceDocumentIndex, load: (URL) -> String?,
                               ancestors: Set<URL>, depth: Int) -> WorkspaceEmbedExpansion {
        guard depth < maximumDepth else {
            return WorkspaceEmbedExpansion(text: "", issues: [String(localized: "埋め込みの展開深度を超えました")])
        }
        guard let target = WorkspaceWikiLinks.resolve(reference.target, from: documentURL,
            index: index) else {
            return WorkspaceEmbedExpansion(text: "", issues: [String(localized: "埋め込み先が見つかりません: \(reference.target)")])
        }
        guard !ancestors.contains(target) else {
            return WorkspaceEmbedExpansion(text: "", issues: [String(localized: "埋め込みに循環参照があります: \(reference.target)")])
        }
        guard let source = load(target), source.utf8.count <= maximumBytes else {
            return WorkspaceEmbedExpansion(text: "", issues: [String(localized: "埋め込み先を読み込めません: \(reference.target)")])
        }
        let selected: String
        if let section = reference.section {
            guard let content = sectionContent(section, in: source) else {
                return WorkspaceEmbedExpansion(text: "", issues: [String(localized: "埋め込み先の見出しが見つかりません: \(section)")])
            }
            selected = content
        } else {
            selected = source
        }
        let analysis = MarkdownAnalysis(selected)
        let excluded = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
            + (analysis.frontMatter.map { [$0.sourceRange] } ?? [])
        let text = selected as NSString
        let lines = MarkdownLineIndex(selected)
        let result = NSMutableString(string: selected)
        var issues: [String] = []
        var replacements: [(NSRange, String)] = []
        for start in lines.starts {
            guard !excluded.contains(where: { NSLocationInRange(start, $0) }) else { continue }
            let lineIndex = lines.line(containingUTF16Offset: start)
            let end = lineIndex < lines.lineCount ? lines.starts[lineIndex] : text.length
            let range = NSRange(location: start, length: end - start)
            let line = text.substring(with: range)
            guard let child = Self.reference(in: line) else { continue }
            let expanded = expand(child, from: target, index: index, load: load,
                ancestors: ancestors.union([target]), depth: depth + 1)
            issues += expanded.issues
            let childText = WorkspaceWikiLinks.resolve(child.target, from: target,
                index: index).map {
                    relocateLocalLinks(in: expanded.text, from: $0, to: target)
                } ?? expanded.text
            replacements.append((range, childText + (line.hasSuffix("\n") ? "\n" : "")))
        }
        for (range, replacement) in replacements.reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }
        return WorkspaceEmbedExpansion(text: result as String, issues: issues)
    }

    private static func sectionContent(_ fragment: String, in source: String) -> String? {
        let analysis = MarkdownAnalysis(source)
        let headings = MarkdownOutline.entries(in: analysis)
        guard let entry = MarkdownHeadingIndex(analysis: analysis).entry(forFragment: fragment) else {
            return nil
        }
        let end = headings.first(where: {
            $0.sourceRange.location > entry.sourceRange.location && $0.level <= entry.level
        })?.sourceRange.location ?? (source as NSString).length
        return (source as NSString).substring(with: NSRange(location: entry.sourceRange.location,
            length: end - entry.sourceRange.location))
    }

    private static func relocateLocalLinks(in source: String, from documentURL: URL,
                                           to containingURL: URL) -> String {
        let analysis = MarkdownAnalysis(source)
        let excluded = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
            + MarkdownInlineSyntax.codeSpanRanges(in: source)
        let context = DocumentContext(fileURL: documentURL)
        let result = NSMutableString(string: source)
        var edits: [(NSRange, String)] = []
        for link in MarkdownLinkSyntax.inlineLinks(in: source) {
            guard !excluded.contains(where: { NSLocationInRange(link.range.location, $0) }) else {
                continue
            }
            let pieces = link.destination.split(separator: "#", maxSplits: 1,
                omittingEmptySubsequences: false)
            guard let destination = context.resolveLocalResource(String(pieces[0])) else {
                continue
            }
            let path = WorkspaceWikiLinks.relativePath(
                from: containingURL.deletingLastPathComponent(), to: destination)
            let fragment = pieces.count == 2 ? "#" + pieces[1] : ""
            edits.append((link.destinationRange,
                MarkdownLinkSyntax.escapeDestination(path + fragment)))
        }
        for (range, value) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            result.replaceCharacters(in: range, with: value)
        }
        return result as String
    }
}
