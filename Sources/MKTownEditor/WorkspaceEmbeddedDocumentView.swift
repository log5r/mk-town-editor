import SwiftUI

struct WorkspaceEmbeddedDocumentView: View {
    let reference: WorkspaceEmbedReference
    let documentURL: URL
    let documents: [URL]
    @ObservedObject var contentRevisions: WorkspaceContentRevisions = .empty
    var diskRevision: Int?
    var documentIndex: WorkspaceDocumentIndex?
    let loadOpenBuffers: ((Set<URL>) throws -> [URL: Data])?
    let onOpen: ((URL) -> Void)?
    var preservesSoftLineBreaks = false
    /// プレビューの表示倍率。文字・数式・字下げを本文と同じ倍率で拡大・縮小する。
    var zoom: Double = 1
    @State private var targetURL: URL?
    @State private var cachedIndex: WorkspaceDocumentIndex?
    @State private var indexedDocuments: [URL] = []
    @State private var expansion: WorkspaceEmbedExpansion?
    @State private var refreshID = 0
    @State private var segments: [WorkspaceEmbedSegment] = []
    @State private var renderedAnalysis: MarkdownAnalysis?
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
                ($0, contentRevisions.values[$0, default: 0])
            }), diskRevision: (diskRevision ?? 0) &+ refreshID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(reference.target, systemImage: "doc.on.doc")
                    .font(PreviewSupplementaryFont.caption(zoom: zoom, weight: .semibold))
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
                    ForEach(segments.indices, id: \.self) { index in
                        segmentView(segments[index])
                    }
                }
                ForEach(expansion.issues.indices, id: \.self) { index in
                    Label(expansion.issues[index], systemImage: "exclamationmark.triangle")
                        .font(PreviewSupplementaryFont.caption(zoom: zoom))
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
        .onChange(of: preservesSoftLineBreaks) { _, _ in
            updateSegments()
        }
        .onChange(of: zoom) { _, _ in
            // 読み込み直さず、読み込み済みの解析結果を新しい倍率で描き直す。
            updateSegments()
        }
        .onChange(of: renderedAnalysis?.identity) { _, _ in
            updateSegments()
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: WorkspaceEmbedSegment) -> some View {
        switch segment {
        case let .text(text):
            WorkspaceEmbedText(text: text, source: expansion?.text ?? "",
                               context: DocumentContext(fileURL: targetURL,
                                                        preservesSoftLineBreaks: preservesSoftLineBreaks))
        case let .codeBlock(block, code, quoteDepth):
            PreviewQuotedCodeBlock(quoteDepth: quoteDepth, onCopy: { _ = MarkdownCodeCopy.copy(block) }) {
                Text(code)
                    .textSelection(.enabled)
            }
        }
    }

    private func refresh(key: RefreshKey) async {
        // Discovering a dependency changes the task key. Its initial result is
        // already current, so that bookkeeping change must not encode it again.
        guard key != completedRefreshKey else { return }
        let revisions = contentRevisions.values
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
                    renderedAnalysis = analysis
                }
                expansion = loaded.expansion
            }
        } catch is CancellationError {
        } catch {
            // Only cancellation is thrown by the background expansion. Buffer
            // conflicts retain the existing disk fallback in the loader.
        }
    }

    private func updateSegments() {
        guard let renderedAnalysis else { return }
        segments = WorkspaceEmbedSegment.render(renderedAnalysis,
            documentContext: DocumentContext(fileURL: targetURL,
                preservesSoftLineBreaks: preservesSoftLineBreaks),
            zoom: zoom)
    }
}

/// 埋め込み文書の文章の部分。
/// `Text` は段落スタイルの字下げを無視するため、`NSTextView`（`HoverLinkText`）で描く。
/// 区間全体を1つの選択面にし、項目をまたいだ範囲選択と、行頭記号・タスクの状態を含むコピーを保つ。
struct WorkspaceEmbedText: View {
    let text: NSAttributedString
    let source: String
    let context: DocumentContext

    var body: some View {
        // 外部ページの題名取得は設定を受け取らないため行わない。
        // `HoverLinkText` は行の余白を持たず、引用の中のコードブロックの縦線（`PreviewQuotedCodeBlock`）と引用記号の位置がそろう。
        HoverLinkText(rendered: text, source: source, context: context, loadsExternalPages: false)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 埋め込み文書の表示単位。コードブロックは文字ごとの背景を外し、通常のプレビューと同じ
/// `PreviewCodeBlockFrame` の枠で囲んで描く（`PreviewQuotedCodeBlock`）。
enum WorkspaceEmbedSegment: Equatable {
    /// 文章の部分。字下げを `PreviewAppKitIndent` で整え、1つの `NSTextView` で描く。
    case text(NSAttributedString)
    case codeBlock(MarkdownBlock, AttributedString, quoteDepth: Int)

    /// - Parameter zoom: プレビューの表示倍率。文字と数式（`PreviewTypography.scaled`）と字下げを同じ倍率で広げる。
    @MainActor
    static func render(_ analysis: MarkdownAnalysis, documentContext: DocumentContext,
                       zoom: Double = 1) -> [Self] {
        MarkdownRenderer.renderSegments(analysis, documentContext: documentContext).map { segment in
            switch segment {
            case let .text(text):
                .text(PreviewTypography.scaledAndAligned(text, by: zoom))
            case let .codeBlock(block, rendered, quoteDepth):
                .codeBlock(block, AttributedString(PreviewTypography.codeBlockBody(
                    PreviewTypography.scaled(rendered, by: zoom))), quoteDepth: quoteDepth)
            }
        }
    }
}

/// Decoded dependency texts, reused while the file's metadata still identifies the same contents.
/// Volumes without a generation identifier re-read on every refresh, since equal size and date
/// do not prove the bytes are unchanged there.
struct WorkspaceEmbedFileCache: Sendable {
    private struct Entry: Sendable {
        let metadata: WorkspaceFileMetadata
        let candidates: [MarkdownTextEncoding]
        let text: String
    }
    private var entries: [URL: Entry] = [:]
    private(set) var readCount = 0
    private let readMetadata: WorkspaceFileMetadata.Reader

    init(readMetadata: @escaping WorkspaceFileMetadata.Reader = WorkspaceFileMetadata.read) {
        self.readMetadata = readMetadata
    }

    mutating func load(_ url: URL, openBuffers: [URL: Data],
                       candidates: [MarkdownTextEncoding] = MarkdownEncodingPreferences.candidates()) -> String? {
        if let data = openBuffers[url] {
            guard data.count <= WorkspaceDocumentEmbed.maximumBytes else { return nil }
            return try? MarkdownDocument.decode(data, candidates: candidates)
        }
        guard let metadata = try? readMetadata(url),
              let size = metadata.size, size <= WorkspaceDocumentEmbed.maximumBytes else {
            entries.removeValue(forKey: url)
            return nil
        }
        if let entry = entries[url], entry.metadata.matchesContent(of: metadata), entry.candidates == candidates {
            return entry.text
        }
        guard let data = try? Data(contentsOf: url),
              let text = try? MarkdownDocument.decode(data, candidates: candidates) else { return nil }
        readCount += 1
        entries[url] = Entry(metadata: metadata, candidates: candidates, text: text)
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
