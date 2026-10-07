import SwiftUI

struct WorkspaceEmbeddedDocumentView: View {
    let reference: WorkspaceEmbedReference
    let documentURL: URL
    let documents: [URL]
    var contentRevision = 0
    var diskRevision: Int?
    var documentIndex: WorkspaceDocumentIndex?
    let loadOpenBuffers: (() throws -> [URL: Data])?
    let onOpen: ((URL) -> Void)?
    @State private var targetURL: URL?
    @State private var cachedIndex: WorkspaceDocumentIndex?
    @State private var indexedDocuments: [URL] = []
    @State private var expansion: WorkspaceEmbedExpansion?
    @State private var refreshID = 0
    @State private var rendered = AttributedString()
    @State private var fileCache = WorkspaceEmbedFileCache()
    @State private var directoryMonitor: WorkspaceDirectoryMonitor?

    private struct RefreshKey: Hashable {
        let reference: WorkspaceEmbedReference
        let document: URL
        let documents: [URL]
        let contentRevision: Int
        let diskRevision: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(reference.target, systemImage: "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let targetURL, let onOpen {
                    Button("元の書類を開く", systemImage: "arrow.up.right") {
                        onOpen(targetURL)
                    }
                    .labelStyle(.iconOnly)
                    .help("元の書類を開く")
                }
            }
            if let expansion {
                if !expansion.text.isEmpty {
                    Text(rendered)
                        .textSelection(.enabled)
                }
                ForEach(expansion.issues.indices, id: \.self) { index in
                    Label(expansion.issues[index], systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("埋め込みを読み込み中")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .task(id: RefreshKey(reference: reference, document: documentURL, documents: documents,
                            contentRevision: contentRevision, diskRevision: (diskRevision ?? 0) &+ refreshID)) { await refresh() }
        .task(id: RefreshKey(reference: reference, document: documentURL, documents: documents,
                             contentRevision: diskRevision == nil ? 0 : 1, diskRevision: 0)) {
            directoryMonitor?.stop(); directoryMonitor = nil
            guard diskRevision == nil else { return }
            var components = documentURL.deletingLastPathComponent().pathComponents
            for url in documents {
                components = Array(zip(components, url.deletingLastPathComponent().pathComponents)
                    .prefix { $0 == $1 }.map { $0.0 })
            }
            let root = URL(fileURLWithPath: NSString.path(withComponents: components))
            directoryMonitor = WorkspaceDirectoryMonitor(root: root) { refreshID &+= 1 }
        }
        .onDisappear { directoryMonitor?.stop(); directoryMonitor = nil }
    }

    private func refresh() async {
        let buffers = (try? loadOpenBuffers?()) ?? [:]
        let reference = reference
        let documentURL = documentURL
        let documents = documents
        let previous = expansion
        let previousTarget = targetURL
        let cache = fileCache
        let index = documentIndex ?? (indexedDocuments == documents ? cachedIndex : nil)
        let worker = Task.detached(priority: .utility) {
            var cache = cache
            let index = index ?? WorkspaceDocumentIndex(documents: documents)
            let target = WorkspaceWikiLinks.resolve(reference.target, from: documentURL, index: index)
            let result = WorkspaceDocumentEmbed.expand(reference, from: documentURL,
                index: index) { url in
                    if Task.isCancelled { return nil }
                    return cache.load(url, openBuffers: buffers)
                }
            let analysis = previous?.text != result.text || previousTarget != target ? MarkdownAnalysis(result.text) : nil
            return (result, analysis, cache, index, target)
        }
        let (result, analysis, cacheResult, indexResult, target) = await withTaskCancellationHandler {
            await worker.value
        } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        fileCache = cacheResult
        cachedIndex = indexResult; indexedDocuments = documents; targetURL = target
        if expansion != result || previousTarget != target {
            if let analysis {
                rendered = AttributedString(MarkdownRenderer.render(analysis,
                    documentContext: DocumentContext(fileURL: targetURL)))
            }
            expansion = result
        }
    }
}

struct WorkspaceEmbedFileCache: Sendable {
    private struct Entry: Sendable {
        let modified: Date?
        let size: Int
        let text: String
    }
    private var entries: [URL: Entry] = [:]
    private(set) var readCount = 0

    mutating func load(_ url: URL, openBuffers: [URL: Data]) -> String? {
        if let data = openBuffers[url] {
            guard data.count <= WorkspaceDocumentEmbed.maximumBytes else { return nil }
            return try? MarkdownDocument.decode(data)
        }
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        guard let values = try? freshURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, size <= WorkspaceDocumentEmbed.maximumBytes else {
            entries.removeValue(forKey: url)
            return nil
        }
        if let entry = entries[url], entry.modified == values.contentModificationDate, entry.size == size {
            return entry.text
        }
        guard let data = try? Data(contentsOf: url),
              let text = try? MarkdownDocument.decode(data) else { return nil }
        readCount += 1
        entries[url] = Entry(modified: values.contentModificationDate, size: size, text: text)
        return text
    }
}
