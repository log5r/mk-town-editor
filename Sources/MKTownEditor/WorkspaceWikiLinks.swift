import Foundation

struct WorkspaceWikiLink: Equatable {
    let range: NSRange
    let targetRange: NSRange
    let target: String
    let alias: String?
}

enum WorkspaceWikiLinks {
    private static let pattern = try! NSRegularExpression(pattern: #"\[\[([^\]\n|]+)(?:\|([^\]\n]+))?\]\]"#)

    static func links(in source: String) -> [WorkspaceWikiLink] {
        let text = source as NSString
        let analysis = MarkdownAnalysis(source)
        let excluded = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
            + MarkdownInlineSyntax.codeSpanRanges(in: source)
            + (analysis.frontMatter.map { [$0.sourceRange] } ?? [])
        return pattern.matches(in: source, range: NSRange(location: 0, length: text.length))
            .compactMap { match in
                let start = match.range.location
                guard !excluded.contains(where: { NSLocationInRange(start, $0) }),
                      !isEscaped(text, at: start),
                      !(start > 0 && text.character(at: start - 1) == 33) else { return nil }
                let target = text.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespaces)
                guard !target.isEmpty else { return nil }
                let aliasRange = match.range(at: 2)
                return WorkspaceWikiLink(range: match.range, targetRange: match.range(at: 1),
                    target: target, alias: aliasRange.location == NSNotFound ? nil
                        : text.substring(with: aliasRange))
            }
    }

    static func link(at selection: NSRange, in source: String) -> WorkspaceWikiLink? {
        links(in: source).first { link in
            selection.location >= link.range.location &&
                NSMaxRange(selection) <= NSMaxRange(link.range)
        }
    }

    /// A path is relative to the containing document. A bare title must be unique in the workspace.
    static func resolve(_ target: String, from documentURL: URL, documents: [URL]) -> URL? {
        guard !target.isEmpty, !target.hasPrefix("/"),
              !target.contains("\\"), !target.contains("#"), !target.contains("?") else { return nil }
        let canonicalDocuments = Set(documents.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        let path = URL(fileURLWithPath: target).pathExtension.isEmpty ? target + ".md" : target
        let relative = documentURL.deletingLastPathComponent().appendingPathComponent(path)
            .resolvingSymlinksInPath().standardizedFileURL
        if canonicalDocuments.contains(relative) { return relative }
        guard !target.contains("/") else { return nil }
        let matches = canonicalDocuments.filter { $0.deletingPathExtension().lastPathComponent ==
            URL(fileURLWithPath: target).deletingPathExtension().lastPathComponent }
        return matches.count == 1 ? matches.first : nil
    }

    static func target(for destination: URL, from documentURL: URL,
                       documents: [URL]) -> String {
        let title = destination.deletingPathExtension().lastPathComponent
        if resolve(title, from: documentURL, documents: documents) ==
            destination.resolvingSymlinksInPath().standardizedFileURL { return title }
        let path = relativePath(from: documentURL.deletingLastPathComponent(), to: destination)
        return path.hasSuffix(".md") ? String(path.dropLast(3)) : path
    }

    static func insertion(in source: String, selection: NSRange, target: String) -> MarkdownEdit? {
        let text = source as NSString
        guard selection.location >= 0, NSMaxRange(selection) <= text.length,
              !target.isEmpty, !target.contains("[["), !target.contains("]]"),
              !target.contains("|") else { return nil }
        if let existing = link(at: selection, in: source) {
            return MarkdownEdit(range: existing.targetRange, replacement: target,
                selection: NSRange(location: existing.targetRange.location + (target as NSString).length,
                    length: 0))
        }
        let alias = selection.length > 0 ? text.substring(with: selection) : nil
        if let alias, alias.contains("|") || alias.contains("]]") || alias.contains("\n") {
            return nil
        }
        let replacement = "[[\(target)\(alias.map { "|" + $0 } ?? "")]]"
        return MarkdownEdit(range: selection, replacement: replacement,
            selection: NSRange(location: selection.location + (replacement as NSString).length,
                length: 0))
    }

    static func conversion(in source: String, selection: NSRange, documentURL: URL,
                           documents: [URL]) -> MarkdownEdit? {
        guard let link = link(at: selection, in: source),
              let target = resolve(link.target, from: documentURL, documents: documents) else { return nil }
        let path = relativePath(from: documentURL.deletingLastPathComponent(), to: target)
        let label = (link.alias ?? target.deletingPathExtension().lastPathComponent)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let replacement = "[\(label)](\(MarkdownLinkSyntax.escapeDestination(path)))"
        return MarkdownEdit(range: link.range, replacement: replacement,
            selection: NSRange(location: link.range.location + (replacement as NSString).length,
                length: 0))
    }

    static func relativePath(from directory: URL, to target: URL) -> String {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let dest = target.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let common = zip(base, dest).prefix(while: { $0.0 == $0.1 }).count
        return (Array(repeating: "..", count: base.count - common) + dest.dropFirst(common))
            .joined(separator: "/")
    }

    private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
        var cursor = location - 1
        while cursor >= 0 && source.character(at: cursor) == 92 { cursor -= 1 }
        return (location - cursor - 1) % 2 == 1
    }
}
