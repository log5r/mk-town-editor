import Foundation

struct WorkspaceBacklink: Identifiable, Sendable {
    let sourceURL: URL
    let relativePath: String
    let sourceRange: NSRange
    let line: Int
    let excerpt: String

    var id: String { "\(sourceURL.path):\(sourceRange.location)" }
}

struct WorkspaceBacklinkIndex: Sendable {
    let backlinks: [WorkspaceBacklink]
    let skippedDocuments: Int
    let isTruncated: Bool

    static func scan(root: URL, targetURL: URL, nodes: [WorkspaceNode],
                     openBuffers: [URL: Data], isTruncated: Bool = false)
        throws -> WorkspaceBacklinkIndex {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let target = targetURL.resolvingSymlinksInPath().standardizedFileURL
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        var backlinks: [WorkspaceBacklink] = []
        var skipped = 0
        let workspaceDocuments = documents(in: nodes)
        let documentURLs = workspaceDocuments.map(\.url)
        let documentIndex = WorkspaceDocumentIndex(documents: documentURLs)
        for node in workspaceDocuments {
            try Task.checkCancellation()
            let sourceURL = node.url.resolvingSymlinksInPath().standardizedFileURL
            guard sourceURL.path.hasPrefix(prefix) else { continue }
            let data: Data
            if let open = openBuffers[sourceURL] {
                data = open
            } else {
                guard let size = try? sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      size <= 8_000_000,
                      let file = try? Data(contentsOf: sourceURL) else {
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
            let analysis = MarkdownAnalysis(source)
            let context = DocumentContext(fileURL: sourceURL)
            let lines = MarkdownLineIndex(source)
            let text = source as NSString
            let relativePath = String(sourceURL.path.dropFirst(prefix.count))
            for item in MarkdownContentInspector.items(in: source, analysis: analysis)
                where item.kind == .link {
                if let frontMatter = analysis.frontMatter,
                   NSIntersectionRange(frontMatter.sourceRange, item.sourceRange).length > 0 {
                    continue
                }
                guard let destination = item.destination,
                      resolves(destination, from: context, sourceURL: sourceURL,
                               to: target) else { continue }
                let line = lines.line(containingUTF16Offset: item.sourceRange.location)
                let start = lines.starts[line - 1]
                let end = line < lines.lineCount ? lines.starts[line] - 1 : text.length
                let excerpt = text.substring(with: NSRange(location: start,
                    length: max(0, end - start)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                backlinks.append(WorkspaceBacklink(sourceURL: sourceURL,
                    relativePath: relativePath, sourceRange: item.sourceRange,
                    line: line, excerpt: String(excerpt.prefix(240))))
            }
            for wiki in WorkspaceWikiLinks.links(in: source) {
                guard WorkspaceWikiLinks.resolve(wiki.target, from: sourceURL,
                    index: documentIndex) == target else { continue }
                let line = lines.line(containingUTF16Offset: wiki.range.location)
                let start = lines.starts[line - 1]
                let end = line < lines.lineCount ? lines.starts[line] - 1 : text.length
                let excerpt = text.substring(with: NSRange(location: start,
                    length: max(0, end - start)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                backlinks.append(WorkspaceBacklink(sourceURL: sourceURL,
                    relativePath: relativePath, sourceRange: wiki.range,
                    line: line, excerpt: String(excerpt.prefix(240))))
            }
        }
        backlinks.sort {
            if $0.relativePath != $1.relativePath {
                return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            return $0.sourceRange.location < $1.sourceRange.location
        }
        return WorkspaceBacklinkIndex(backlinks: backlinks,
            skippedDocuments: skipped, isTruncated: isTruncated)
    }

    private static func resolves(_ destination: String, from context: DocumentContext,
                                 sourceURL: URL, to target: URL) -> Bool {
        let path = String(destination.split(separator: "#", maxSplits: 1,
            omittingEmptySubsequences: false).first ?? "")
        let resolved = path.isEmpty ? sourceURL : context.resolveLocalResource(path)
        return resolved?.resolvingSymlinksInPath().standardizedFileURL == target
    }

    private static func documents(in nodes: [WorkspaceNode]) -> [WorkspaceNode] {
        nodes.flatMap { node in
            if let children = node.children { return documents(in: children) }
            return node.isEditableDocument ? [node] : []
        }
    }
}
