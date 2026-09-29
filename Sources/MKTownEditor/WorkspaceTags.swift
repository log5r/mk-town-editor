import Foundation

enum MarkdownTags {
    private static let inlinePattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_/#])#([\p{L}_][\p{L}\p{N}_/-]*)"#)
    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>]+"#)
    private static let frontMatterKey = try! NSRegularExpression(pattern: #"^tags:[ \t]*(.*)$"#)
    private static let frontMatterItem = try! NSRegularExpression(pattern: #"^[ \t]+-[ \t]+(.+)$"#)

    static func inDocument(_ source: String, analysis: MarkdownAnalysis? = nil) -> Set<String> {
        let text = source as NSString
        guard text.length > 0 else { return [] }
        let analysis = analysis ?? MarkdownAnalysis(source)
        var result = frontMatterTags(in: analysis.frontMatter?.content ?? "")
        var excluded = analysis.blocks.filter { $0.kind == .codeBlock }.map(\.sourceRange)
        excluded += MarkdownInlineSyntax.codeSpanRanges(in: source)
        excluded += MarkdownLinkSyntax.inlineLinks(in: source).map(\.destinationRange)
        if let range = analysis.frontMatter?.sourceRange { excluded.append(range) }
        excluded += urlPattern.matches(in: source, range: NSRange(location: 0, length: text.length))
            .map(\.range)
        var excludedOffsets = IndexSet()
        for range in excluded where range.length > 0 {
            excludedOffsets.insert(integersIn: range.location..<NSMaxRange(range))
        }
        for match in inlinePattern.matches(in: source,
            range: NSRange(location: 0, length: text.length)) {
            let tagRange = match.range(at: 1)
            guard !excludedOffsets.intersects(integersIn: match.range.location..<NSMaxRange(match.range))
            else { continue }
            result.insert(text.substring(with: tagRange).lowercased())
        }
        return result
    }

    private static func frontMatterTags(in content: String) -> Set<String> {
        let lines = content.components(separatedBy: .newlines)
        var tags: Set<String> = []
        var readingList = false
        for line in lines {
            let text = line as NSString
            let full = NSRange(location: 0, length: text.length)
            if let match = frontMatterKey.firstMatch(in: line, range: full) {
                readingList = true
                let value = text.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespaces)
                let contents = value.hasPrefix("[") && value.hasSuffix("]")
                    ? String(value.dropFirst().dropLast()) : value
                for item in contents.split(separator: ",", omittingEmptySubsequences: true) {
                    if let tag = normalize(String(item)) { tags.insert(tag) }
                }
                continue
            }
            guard readingList else { continue }
            if let match = frontMatterItem.firstMatch(in: line, range: full) {
                if let tag = normalize(text.substring(with: match.range(at: 1))) {
                    tags.insert(tag)
                }
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                readingList = false
            }
        }
        return tags
    }

    private static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = value.count >= 2 &&
            ((value.first == "\"" && value.last == "\"") ||
             (value.first == "'" && value.last == "'"))
        if quoted {
            value = String(value.dropFirst().dropLast())
        } else if let comment = value.firstIndex(of: "#"),
                  comment > value.startIndex,
                  value[value.index(before: comment)].isWhitespace {
            value = String(value[..<comment]).trimmingCharacters(in: .whitespaces)
        }
        if !quoted && value.hasPrefix("#") { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? nil : value
    }
}

struct WorkspaceTagDocument: Identifiable, Sendable {
    let url: URL
    let relativePath: String
    var id: URL { url }
}

struct WorkspaceTagIndex: Sendable {
    let documentsByTag: [String: [WorkspaceTagDocument]]
    let skippedDocuments: Int
    let isTruncated: Bool

    var tags: [String] { documentsByTag.keys.sorted() }

    func documents(for tag: String) -> [WorkspaceTagDocument] {
        documentsByTag[tag] ?? []
    }

    static func scan(root: URL, nodes: [WorkspaceNode],
                     openBuffers: [URL: Data], isTruncated: Bool = false) throws -> WorkspaceTagIndex {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        var byTag: [String: [WorkspaceTagDocument]] = [:]
        var skipped = 0
        for node in documents(in: nodes) {
            try Task.checkCancellation()
            let url = node.url.resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(prefix) else { continue }
            let data: Data
            if let open = openBuffers[url] {
                data = open
            } else {
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 8_000_000,
                      let file = try? Data(contentsOf: url) else {
                    skipped += 1
                    continue
                }
                data = file
            }
            guard data.count <= 8_000_000,
                  let source = try? MarkdownDocument.decode(data) else {
                skipped += 1
                continue
            }
            let document = WorkspaceTagDocument(url: url,
                relativePath: String(url.path.dropFirst(prefix.count)))
            for tag in MarkdownTags.inDocument(source) {
                byTag[tag, default: []].append(document)
            }
        }
        for tag in byTag.keys {
            byTag[tag]?.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        }
        return WorkspaceTagIndex(documentsByTag: byTag, skippedDocuments: skipped,
                                 isTruncated: isTruncated)
    }

    private static func documents(in nodes: [WorkspaceNode]) -> [WorkspaceNode] {
        nodes.flatMap { node in
            if let children = node.children { return documents(in: children) }
            return node.isEditableDocument ? [node] : []
        }
    }
}
