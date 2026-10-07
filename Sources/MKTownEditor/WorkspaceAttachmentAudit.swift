import Foundation

struct WorkspaceAttachmentEntry: Identifiable, Sendable {
    let url: URL
    let sources: [URL]
    /// 確認時にファイルが存在したか。表示のたびにファイルシステムを調べないために保持する。
    var exists = true

    var id: URL { url }
}

struct WorkspaceAttachmentAuditResult: Sendable {
    let missing: [WorkspaceAttachmentEntry]
    let unused: [WorkspaceAttachmentEntry]
    let used: [WorkspaceAttachmentEntry]
    var skippedDocuments: [URL] = []
    var isTruncated = false
}

enum WorkspaceAttachmentAudit {
    static func scan(root: URL, openDocuments: [URL: Data] = [:]) async throws -> WorkspaceAttachmentAuditResult {
        let index = WorkspaceFileIndex.scan(root: root)
        var skipped: [URL] = []
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
            guard let data = try? openDocuments[key] ?? Data(contentsOf: document),
                  let markdown = try? MarkdownDocument.decode(data) else {
                skipped.append(document)
                continue
            }
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
            let resolved = MarkdownRenderer.resolveReferences(in: masked as String,
                                                              using: analysis.references)
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
        func entries(_ urls: [URL], exist: Bool = true) -> [WorkspaceAttachmentEntry] {
            urls.map { WorkspaceAttachmentEntry(url: $0,
                sources: Array(references[$0] ?? []).sorted { $0.path < $1.path }, exists: exist) }
                .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        }
        let missing = entries(references.keys.filter { !FileManager.default.fileExists(atPath: $0.path) },
                              exist: false)
        let assetKeys = Set(assets.map { $0.resolvingSymlinksInPath().standardizedFileURL })
        let unused = skipped.isEmpty && !index.isTruncated ? entries(assetKeys.filter { references[$0] == nil }) : []
        let used = entries(assetKeys.filter { references[$0] != nil })
        return WorkspaceAttachmentAuditResult(missing: missing, unused: unused, used: used,
            skippedDocuments: skipped, isTruncated: index.isTruncated)
    }
}
