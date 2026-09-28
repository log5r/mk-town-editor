import Foundation

struct WorkspaceAttachmentEntry: Identifiable, Sendable {
    let url: URL
    let sources: [URL]

    var id: URL { url }
}

struct WorkspaceAttachmentAuditResult: Sendable {
    let missing: [WorkspaceAttachmentEntry]
    let unused: [WorkspaceAttachmentEntry]
    let used: [WorkspaceAttachmentEntry]
}

enum WorkspaceAttachmentAudit {
    static func scan(root: URL, openDocuments: [URL: Data] = [:]) async throws -> WorkspaceAttachmentAuditResult {
        let index = WorkspaceFileIndex.scan(root: root)
        guard !index.isTruncated else { throw WorkspaceFileOperationError.indexTruncated }
        var documents: [URL] = []
        var assets: [URL] = []
        func collect(_ nodes: [WorkspaceNode]) {
            for node in nodes {
                if let children = node.children { collect(children) }
                else if node.isEditableDocument { documents.append(node.url) }
                else if node.url.pathComponents.contains("assets") ||
                    node.url.pathComponents.contains("images") { assets.append(node.url) }
            }
        }
        collect(index.nodes)
        var references: [URL: Set<URL>] = [:]
        for document in documents {
            try Task.checkCancellation()
            let key = document.resolvingSymlinksInPath().standardizedFileURL
            let data = try openDocuments[key] ?? Data(contentsOf: document)
            let markdown = try MarkdownDocument.decode(data)
            let analysis = MarkdownAnalysis(markdown)
            let masked = NSMutableString(string: markdown)
            for block in analysis.blocks.filter({ $0.kind == .codeBlock })
                .sorted(by: { $0.sourceRange.location > $1.sourceRange.location }) {
                masked.replaceCharacters(in: block.sourceRange,
                    with: String(repeating: " ", count: block.sourceRange.length))
            }
            for range in MarkdownInlineSyntax.codeSpanRanges(in: masked as String)
                .sorted(by: { $0.location > $1.location }) {
                masked.replaceCharacters(in: range,
                    with: String(repeating: " ", count: range.length))
            }
            let maskedSource = masked as String
            let resolved = await MainActor.run {
                MarkdownRenderer.resolveReferences(in: maskedSource, using: analysis.references)
            }
            let context = DocumentContext(fileURL: document)
            for link in MarkdownLinkSyntax.inlineLinks(in: resolved) {
                guard let url = context.resolveLocalResource(link.destination),
                      url.isFileURL else { continue }
                let target = url.resolvingSymlinksInPath().standardizedFileURL
                let isAttachment = link.isImage || ["pdf", "png", "jpg", "jpeg", "gif", "webp",
                    "heic", "tif", "tiff", "bmp"].contains(target.pathExtension.lowercased())
                guard isAttachment else { continue }
                references[target, default: []].insert(key)
            }
        }
        func entries(_ urls: [URL]) -> [WorkspaceAttachmentEntry] {
            urls.map { WorkspaceAttachmentEntry(url: $0,
                sources: Array(references[$0] ?? []).sorted { $0.path < $1.path }) }
                .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        }
        let missing = entries(references.keys.filter { !FileManager.default.fileExists(atPath: $0.path) })
        let assetKeys = Set(assets.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        let unused = entries(assetKeys.filter { references[$0] == nil })
        let used = entries(assetKeys.filter { references[$0] != nil })
        return WorkspaceAttachmentAuditResult(missing: missing, unused: unused, used: used)
    }
}
