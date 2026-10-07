import SwiftUI

struct WorkspaceEmbeddedDocumentView: View {
    let reference: WorkspaceEmbedReference
    let documentURL: URL
    let documents: [URL]
    var contentRevisions: [URL: Int] = [:]
    var diskRevision: Int?
    var documentIndex: WorkspaceDocumentIndex?
    let loadOpenBuffers: ((Set<URL>) throws -> [URL: Data])?
    let onOpen: ((URL) -> Void)?
    @State private var targetURL: URL?
    @State private var cachedIndex: WorkspaceDocumentIndex?
    @State private var indexedDocuments: [URL] = []
    @State private var expansion: WorkspaceEmbedExpansion?
    @State private var refreshID = 0
    @State private var rendered = AttributedString()
    @State private var fileCache = WorkspaceEmbedFileCache()
    @State private var directoryMonitor: WorkspaceDirectoryMonitor?
    @State private var dependencies: Set<URL> = []
    @State private var completedRefreshKey: RefreshKey?

    private struct RefreshKey: Hashable {
        let reference: WorkspaceEmbedReference
        let document: URL
        let documents: [URL]
        let contentRevisions: [URL: Int]
        let diskRevision: Int
    }

    private func refreshKey(dependencies: Set<URL>) -> RefreshKey {
        RefreshKey(reference: reference, document: documentURL, documents: documents,
            contentRevisions: Dictionary(uniqueKeysWithValues: dependencies.map {
                ($0, contentRevisions[$0, default: 0])
            }), diskRevision: (diskRevision ?? 0) &+ refreshID)
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
        .task(id: refreshKey(dependencies: dependencies)) {
            await refresh(key: refreshKey(dependencies: dependencies))
        }
        .task(id: RefreshKey(reference: reference, document: documentURL, documents: documents,
                             contentRevisions: [:], diskRevision: diskRevision == nil ? 0 : 1)) {
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
        .onDisappear {
            directoryMonitor?.stop(); directoryMonitor = nil
            completedRefreshKey = nil
        }
    }

    private func refresh(key: RefreshKey) async {
        // Discovering a dependency changes the task key. Its initial result is
        // already current, so that bookkeeping change must not encode it again.
        guard key != completedRefreshKey else { return }
        let revisions = contentRevisions
        do {
            let loaded = try await WorkspaceEmbedLoader.load(reference, from: documentURL,
                documents: documents, index: documentIndex ?? (indexedDocuments == documents ? cachedIndex : nil),
                dependencies: dependencies, cache: fileCache, previous: expansion,
                previousTarget: targetURL, loadOpenBuffers: loadOpenBuffers)
            try Task.checkCancellation()
            fileCache = loaded.cache
            cachedIndex = loaded.index; indexedDocuments = documents; targetURL = loaded.target
            dependencies = loaded.dependencies
            completedRefreshKey = RefreshKey(reference: key.reference, document: key.document,
                documents: key.documents, contentRevisions: Dictionary(uniqueKeysWithValues:
                    loaded.dependencies.map { ($0, revisions[$0, default: 0]) }), diskRevision: key.diskRevision)
            if expansion != loaded.expansion || loaded.analysis != nil {
                if let analysis = loaded.analysis {
                    rendered = AttributedString(MarkdownRenderer.render(analysis,
                        documentContext: DocumentContext(fileURL: targetURL)))
                }
                expansion = loaded.expansion
            }
        } catch is CancellationError {
        } catch {
            // Only cancellation is thrown by the background expansion. Buffer
            // conflicts retain the existing disk fallback in the loader.
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

/// Discover nested dependencies on the worker, then request only their open
/// buffers on the main actor. Never encode unrelated open documents.
@MainActor
enum WorkspaceEmbedLoader {
    struct Result: Sendable {
        let expansion: WorkspaceEmbedExpansion
        let dependencies: Set<URL>
        let cache: WorkspaceEmbedFileCache
        let index: WorkspaceDocumentIndex
        let target: URL?
        let analysis: MarkdownAnalysis?
    }

    static func load(_ reference: WorkspaceEmbedReference, from documentURL: URL,
                     documents: [URL], index suppliedIndex: WorkspaceDocumentIndex? = nil,
                     dependencies: Set<URL> = [], cache initialCache: WorkspaceEmbedFileCache = .init(),
                     previous: WorkspaceEmbedExpansion? = nil, previousTarget: URL? = nil,
                     loadOpenBuffers: ((Set<URL>) throws -> [URL: Data])?) async throws -> Result {
        try Task.checkCancellation()
        let index: WorkspaceDocumentIndex
        if let suppliedIndex { index = suppliedIndex }
        else { index = try await DocumentWork.perform { WorkspaceDocumentIndex(documents: documents) } }
        var available = dependencies
        var buffers = available.isEmpty ? [:] : (try? loadOpenBuffers?(available)) ?? [:]
        var cache = initialCache
        while true {
            try Task.checkCancellation()
            let known = available, snapshots = buffers, previousCache = cache
            let result = try await DocumentWork.perform {
                var cache = previousCache
                var requested: Set<URL> = []
                let target = WorkspaceWikiLinks.resolve(reference.target, from: documentURL, index: index)
                let expansion = WorkspaceDocumentEmbed.expand(reference, from: documentURL, index: index) { url in
                    requested.insert(url)
                    guard known.contains(url), !Task.isCancelled else { return nil }
                    return cache.load(url, openBuffers: snapshots)
                }
                let complete = requested.isSubset(of: known)
                let analysis = complete && (previous?.text != expansion.text || previousTarget != target)
                    ? MarkdownAnalysis(expansion.text) : nil
                return Result(expansion: expansion, dependencies: requested, cache: cache,
                    index: index, target: target, analysis: analysis)
            }
            let missing = result.dependencies.subtracting(available)
            guard !missing.isEmpty else { return result }
            try Task.checkCancellation()
            buffers.merge((try? loadOpenBuffers?(missing)) ?? [:]) { _, new in new }
            available.formUnion(missing)
            cache = result.cache
        }
    }
}
