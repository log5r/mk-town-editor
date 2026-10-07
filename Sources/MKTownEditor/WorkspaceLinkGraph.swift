import Foundation

struct WorkspaceGraphEdge: Hashable, Sendable {
    let source: URL
    let target: URL
}

struct WorkspaceGraphViewData: Sendable {
    let nodes: [URL]
    let edges: [WorkspaceGraphEdge]
    let isLimited: Bool
}

struct WorkspaceLinkGraph: Sendable {
    let nodes: [URL]
    let edges: [WorkspaceGraphEdge]
    let skippedDocuments: Int
    let isTruncated: Bool

    static func scan(root: URL, nodes: [WorkspaceNode],
                     openBuffers: [URL: Data], isTruncated: Bool = false) throws -> Self {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        func flatten(_ nodes: [WorkspaceNode]) -> [URL] {
            nodes.flatMap { node in
                if let children = node.children { return flatten(children) }
                return node.isEditableDocument ? [node.url] : []
            }
        }
        let documents = flatten(nodes).map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { $0.path.hasPrefix(prefix) }
        let allowed = Set(documents)
        let documentIndex = WorkspaceDocumentIndex(documents: documents)
        var edges = Set<WorkspaceGraphEdge>()
        var skipped = 0
        for sourceURL in documents {
            try Task.checkCancellation()
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
                  let text = try? MarkdownDocument.decode(data) else {
                skipped += 1
                continue
            }
            let analysis = MarkdownAnalysis(text)
            let context = DocumentContext(fileURL: sourceURL)
            func add(_ target: URL?) {
                guard let target = target?.resolvingSymlinksInPath().standardizedFileURL,
                      target != sourceURL, allowed.contains(target) else { return }
                edges.insert(WorkspaceGraphEdge(source: sourceURL, target: target))
            }
            for item in MarkdownContentInspector.items(in: text, analysis: analysis)
                where item.kind == .link {
                if let frontMatter = analysis.frontMatter,
                   NSIntersectionRange(frontMatter.sourceRange, item.sourceRange).length > 0 {
                    continue
                }
                guard let destination = item.destination else { continue }
                let path = String(destination.split(separator: "#", maxSplits: 1,
                    omittingEmptySubsequences: false)[0])
                add(path.isEmpty ? nil : context.resolveLocalResource(path))
            }
            for wiki in WorkspaceWikiLinks.links(in: text) {
                add(WorkspaceWikiLinks.resolve(wiki.target, from: sourceURL,
                    index: documentIndex))
            }
            for embed in WorkspaceDocumentEmbed.links(in: text) {
                add(WorkspaceWikiLinks.resolve(embed.target, from: sourceURL,
                    index: documentIndex))
            }
        }
        return Self(nodes: documents.sorted { $0.path < $1.path },
            edges: edges.sorted {
                if $0.source.path != $1.source.path { return $0.source.path < $1.source.path }
                return $0.target.path < $1.target.path
            }, skippedDocuments: skipped, isTruncated: isTruncated)
    }

    func view(around focus: URL?, showsAll: Bool, limit: Int = 150) -> WorkspaceGraphViewData {
        let maximum = max(1, limit)
        let selected: [URL]
        if showsAll || focus == nil {
            selected = Array(nodes.prefix(maximum))
        } else {
            let focus = focus!.resolvingSymlinksInPath().standardizedFileURL
            let neighbors = Set(edges.compactMap { edge -> URL? in
                if edge.source == focus { return edge.target }
                if edge.target == focus { return edge.source }
                return nil
            })
            selected = ([focus] + neighbors.sorted { $0.path < $1.path })
                .filter { nodes.contains($0) }
                .prefix(maximum).map { $0 }
        }
        let selectedSet = Set(selected)
        return WorkspaceGraphViewData(nodes: selected,
            edges: edges.filter { selectedSet.contains($0.source) && selectedSet.contains($0.target) },
            isLimited: showsAll || focus == nil ? nodes.count > selected.count :
                edges.contains { edge in
                    (edge.source == focus || edge.target == focus) &&
                        (!selectedSet.contains(edge.source) || !selectedSet.contains(edge.target))
                })
    }
}
