import AppKit
import QuickLookUI
import SwiftUI

/// プレビューの移動先。解析ごとに変わるブロック番号ではなく原文の位置で保持し、
/// 表示中の解析結果に照らして移動先のブロックを決める。
struct PreviewNavigationTarget: Equatable {
    let sourceLocation: Int
    let sequence: Int
    /// 移動を要求した時点の原文。表示中の解析がこの原文のものになるまで、移動は確定しない。
    var source: String? = nil

    /// 表示中の原文で移動先を解決できたか。解析待ちの古い表示で解決した移動は、
    /// 一致する解析結果が届いた時にもう一度適用する。
    func isSettled(byDisplayedSource displayedSource: String) -> Bool {
        source == nil || source == displayedSource
    }

    /// 要求後に初めて表示が新しい解析に変わった時は、原文が一致しなくても確定する。
    /// 要求した原文の解析が続く編集で取り消された場合に、古い移動を繰り返さないため。
    func settles(afterAnalysisChange: Bool, displayedSource: String) -> Bool {
        afterAnalysisChange || isSettled(byDisplayedSource: displayedSource)
    }

    func presentationID(in analysis: MarkdownAnalysis, presentationIDs: [Int: String],
                        index: PreviewScrollIndex? = nil) -> String? {
        PreviewScrollSync.block(containingOrBefore: sourceLocation, in: analysis, index: index)
            .flatMap { presentationIDs[$0.id] }
    }
}

private struct PreviewBlockRow: Identifiable {
    let block: MarkdownBlock
    let id: String
}

struct MarkdownPreview: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var renderCache = PreviewRenderCache()
    @ObservedObject private var remoteImages = RemoteImageStore.shared
    @ObservedObject private var localImages = LocalImageStore.shared
    @State private var citationCatalog = MarkdownCitationCatalog.empty
    @State private var inspectedImage: ImageInspectionItem?
    /// 要求した原文に一致する表示で適用し終えた移動の番号。
    @State private var settledNavigationSequence: Int?
    let markdown: String
    let documentContext: DocumentContext
    var onToggleTask: ((Int) -> Void)? = nil
    var snapshot: DocumentSnapshot?
    var usesSharedAnalysis = false
    var navigationTarget: PreviewNavigationTarget?
    var searchRange: NSRange?
    var onOpenHeading: ((String) -> Void)?
    var onOpenDocument: ((URL) -> Void)?
    var workspaceDocumentURLs: [URL] = []
    var workspaceContentRevisions: WorkspaceContentRevisions = .empty
    var workspaceDiskRevision: Int?
    var workspaceIndex: WorkspaceDocumentIndex?
    var loadWorkspaceOpenBuffers: ((Set<URL>) throws -> [URL: Data])?
    var onOpenEmbeddedDocument: ((URL) -> Void)?
    var onVisibleBlockChange: ((Int) -> Void)?
    var onRevealSource: ((NSRange) -> Void)?
    var showsFrontMatter = false
    var zoom: Double = 1
    var loadsRemoteImages = false
    var loadsExternalLinkPreviews = false
    var theme: PreviewTheme = .system
    var bodyWidth = 900

    /// 外部画像の読み込み条件。スナップショットがあれば背景で抽出済みのURL集合を使い、
    /// 入力でURLが変わらない限りタスクを再起動しない。
    private struct RemoteImageWork: Equatable {
        let isEnabled: Bool
        let urls: Set<URL>?
        let sourceHash: Int
    }

    private var remoteImageWork: RemoteImageWork {
        guard loadsRemoteImages else { return RemoteImageWork(isEnabled: false, urls: [], sourceHash: 0) }
        if let snapshot, snapshot.source == markdown {
            return RemoteImageWork(isEnabled: true, urls: snapshot.remoteImageURLs, sourceHash: 0)
        }
        return RemoteImageWork(isEnabled: true, urls: nil, sourceHash: markdown.hashValue)
    }

    private var resourceRevision: Int { remoteImages.revision &+ localImages.revision }

    /// 描画に渡す文脈。参考文献は背景で読み込んだものを使い、描画中にディスクを読まない。
    private var renderContext: DocumentContext { renderContext(for: nil) }

    /// `analysis` が共有スナップショット自身の解析結果なら、スナップショットの字句（バックグラウンドで求めた版）を渡す。
    /// ブロックIDは解析結果ごとにしか意味を持たないため、別の解析結果には渡さない。
    private func renderContext(for analysis: MarkdownAnalysis?) -> DocumentContext {
        var context = documentContext
        context.citationCatalog = citationCatalog
        if let snapshot, let analysis, snapshot.analysis.identity === analysis.identity {
            context.codeSyntaxTokens = snapshot.codeSyntaxTokens
        }
        return context
    }

    private struct CitationWatch: Equatable {
        let fileURL: URL?
        let isActive: Bool
    }

    private var citationWatch: CitationWatch {
        let isActive = documentContext.markdownDialect == .extended && documentContext.fileURL != nil &&
            (snapshot?.analysis.containsCitationSyntax ?? markdown.contains("[@"))
        return CitationWatch(fileURL: documentContext.fileURL, isActive: isActive)
    }

    var body: some View {
        Group {
        if usesSharedAnalysis && snapshot == nil {
            ProgressView("プレビューを準備中")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let analysis = snapshot?.analysis ?? MarkdownAnalysis(markdown,
                dialect: documentContext.markdownDialect)
            let matchingSnapshot = snapshot.flatMap { $0.analysis.identity === analysis.identity ? $0 : nil }
            if onVisibleBlockChange != nil || onRevealSource != nil ||
                theme != .system || bodyWidth != 900 ||
                (showsFrontMatter && analysis.frontMatter != nil) ||
                (matchingSnapshot?.needsStructuredPreview
                    ?? PreviewStructure.needsStructuredLayout(analysis, source: markdown)) {
                let layout = matchingSnapshot?.previewLayout ?? PreviewLayoutIndex(analysis)
                let presentationIDs = snapshot?.blockPresentationIDs ?? PreviewBlockIdentity.identifiers(in: analysis)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if showsFrontMatter, let frontMatter = analysis.frontMatter {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("フロントマター").font(.headline)
                                    Text(frontMatter.raw)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color.secondary.opacity(0.08))
                                .cornerRadius(8)
                                .padding(.bottom, 16)
                            }
                            ForEach(layout.visibleBlocks.map { block in
                                PreviewBlockRow(block: block, id: presentationIDs[block.id] ?? String(block.id))
                            }) { row in
                                let block = row.block
                                HStack(alignment: .top, spacing: 8) {
                                    ForEach(0..<layout.quoteDepth(for: block.id), id: \.self) { _ in
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.5))
                                            .frame(width: 2)
                                            .accessibilityHidden(true)
                                    }
                                    if let callout = block.calloutKind {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: callout.symbolName)
                                                .accessibilityHidden(true)
                                            inlineText(MarkdownRenderer.$localImageRequester.withValue(renderCache.imageRequester) {
                                                MarkdownRenderer.renderCallout(block, in: analysis,
                                                                               documentContext: renderContext)
                                            })
                                        }
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.accentColor.opacity(0.08))
                                        .cornerRadius(8)
                                        .accessibilityLabel("\(callout.title)。\(block.content)")
                                    } else if documentContext.markdownDialect == .extended,
                                              block.kind == .paragraph,
                                              let reference = WorkspaceDocumentEmbed.reference(in: block.content),
                                              let documentURL = documentContext.fileURL {
                                        WorkspaceEmbeddedDocumentView(reference: reference,
                                            documentURL: documentURL,
                                            documents: workspaceDocumentURLs,
                                            contentRevisions: workspaceContentRevisions,
                                            diskRevision: workspaceDiskRevision,
                                            documentIndex: workspaceIndex,
                                            loadOpenBuffers: loadWorkspaceOpenBuffers,
                                            onOpen: onOpenEmbeddedDocument)
                                    } else if let media = MarkdownMedia(block, dialect: analysis.dialect) {
                                        MarkdownMediaPreview(media: media, documentContext: documentContext)
                                    } else if documentContext.markdownDialect == .extended,
                                              block.kind == .paragraph,
                                              let formula = MarkdownMath.displayFormula(block.content),
                                              renderCache.canRenderDisplayFormula(formula) {
                                        HStack {
                                            MarkdownMathView(formula: formula)
                                                .accessibilityLabel(formula.latex)
                                            if let target = analysis.crossReferences.target(forBlockID: block.id) {
                                                Text(target.label).foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                    } else if let table = block.table {
                                        VStack(alignment: .leading) {
                                            if let target = analysis.crossReferences.target(forBlockID: block.id) {
                                                Text(target.label).font(.caption).foregroundStyle(.secondary)
                                            }
                                            tableView(table, in: analysis)
                                        }
                                    } else if block.kind == .blank {
                                        Text(" ").frame(height: 12)
                                    } else if MermaidDiagram.isDiagram(block) {
                                        MermaidDiagramView(source: block.content)
                                    } else if block.kind == .codeBlock,
                                              let kind = ExternalDiagramKind(language: block.codeLanguage) {
                                        ExternalDiagramView(source: block.content, kind: kind)
                                    } else if block.kind == .codeBlock {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Spacer()
                                                Button("コードをコピー", systemImage: "doc.on.doc") {
                                                    _ = MarkdownCodeCopy.copy(block)
                                                }
                                                .labelStyle(.iconOnly)
                                                .buttonStyle(.borderless)
                                                .help("フェンスを除いたコード本文をコピー")
                                            }
                                            blockText(block, in: analysis)
                                        }
                                    } else if let task = block.task {
                                        taskView(block, task: task, in: analysis)
                                    } else {
                                        blockText(block, in: analysis)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(searchRange.map {
                                    NSLocationInRange($0.location, block.sourceRange)
                                } == true ? Color.accentColor.opacity(0.12) : Color.clear)
                                .id(row.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: PreviewBlockOriginsKey.self,
                                        value: [block.id: geometry.frame(in: .named("markdownPreview")).minY])
                                })
                                .contextMenu {
                                    Button("原文へ移動", systemImage: "text.cursor") {
                                        onRevealSource?(block.sourceRange)
                                    }
                                }
                                .accessibilityAction(named: "原文へ移動") {
                                    onRevealSource?(block.sourceRange)
                                }
                            }
                            if !analysis.footnotes.entries.isEmpty {
                                Text("脚注").font(.headline)
                                    .padding(.top, 20)
                                ForEach(analysis.footnotes.entries, id: \.number) { note in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(note.number).")
                                        inlineText(MarkdownRenderer.$localImageRequester.withValue(renderCache.imageRequester) {
                                            MarkdownRenderer.renderTableCell(note.content, in: analysis,
                                                                             documentContext: renderContext)
                                        })
                                        Button("本文に戻る", systemImage: "arrow.uturn.backward") {
                                            if let block = layout.visibleBlocks.first(where: {
                                                NSLocationInRange(note.firstReferenceRange.location,
                                                                  $0.sourceRange)
                                            }), let id = presentationIDs[block.id] {
                                                proxy.scrollTo(id, anchor: .center)
                                            }
                                        }
                                        .labelStyle(.iconOnly)
                                    }
                                    .id("footnote-\(note.number)")
                                }
                            }
                            if documentContext.markdownDialect == .extended,
                               citationCatalog.hasCitation(in: analysis) {
                                Text("参考文献").font(.headline).padding(.top, 20)
                                ForEach(Array(citationCatalog.entries.enumerated()), id: \.element.key) { index, entry in
                                    Text(verbatim: "\(index + 1). \(entry.bibliographyText)")
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: CGFloat(bodyWidth), alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                    }
                    .coordinateSpace(name: "markdownPreview")
                    .focusable()
                    .onAppear {
                        applyNavigation(navigationTarget, force: true, proxy: proxy, analysis: analysis,
                                        presentationIDs: presentationIDs, index: matchingSnapshot?.scrollIndex)
                    }
                    .onChange(of: navigationTarget) { _, target in
                        applyNavigation(target, force: true, proxy: proxy, analysis: analysis,
                                        presentationIDs: presentationIDs, index: matchingSnapshot?.scrollIndex)
                    }
                    .onChange(of: analysis.identity) { _, _ in
                        // 編集直後の移動は古い表示で解決している。要求した原文の解析が届いたら一度だけ合わせ直す。
                        applyNavigation(navigationTarget, force: false, proxy: proxy, analysis: analysis,
                                        presentationIDs: presentationIDs, index: matchingSnapshot?.scrollIndex)
                    }
                    .onPreferenceChange(PreviewBlockOriginsKey.self) { origins in
                        if let blockID = PreviewScrollSync.topBlockID(from: origins) {
                            onVisibleBlockChange?(blockID)
                        }
                    }
                    .environment(\.openURL, OpenURLAction { url in
                        if let imageURL = MarkdownImageInspectionLink.destination(url) {
                            inspectedImage = ImageInspectionItem(url: imageURL)
                            return .handled
                        }
                        if let fileURL = MarkdownAttachmentInspectionLink.localFile(url,
                            context: documentContext) {
                            inspectedImage = ImageInspectionItem(url: fileURL)
                            return .handled
                        }
                        if url.scheme == "mktown-footnote" {
                            proxy.scrollTo("footnote-\(url.lastPathComponent)", anchor: .center)
                            return .handled
                        }
                        if url.scheme == "mktown-crossref",
                           let target = analysis.crossReferences.targets.first(where: {
                               $0.key == url.lastPathComponent
                           }), let id = presentationIDs[target.blockID] {
                            proxy.scrollTo(id, anchor: .center)
                            return .handled
                        }
                        if let fragment = MarkdownHeadingIndex.localFragment(in: url),
                           let onOpenHeading {
                            onOpenHeading(fragment)
                            return .handled
                        }
                        if MarkdownDocumentLink(url: url, context: documentContext) != nil,
                           let onOpenDocument {
                            onOpenDocument(url)
                            return .handled
                        }
                        return .systemAction
                    })
                }
            } else {
                MarkdownTextPreview(markdown: markdown, documentContext: renderContext(for: snapshot?.analysis),
                                    imageRequester: renderCache.imageRequester,
                                    analysis: snapshot?.analysis, onOpenHeading: onOpenHeading,
                                    onOpenDocument: onOpenDocument, zoom: zoom,
                                    remoteRevision: resourceRevision,
                                    loadsExternalLinkPreviews: loadsExternalLinkPreviews,
                                    onInspectImage: { inspectedImage = ImageInspectionItem(url: $0) })
            }
        }
        }
        .environment(\.colorScheme, theme.colorScheme ?? colorScheme)
        .background(theme.background.map { Color(nsColor: $0) } ?? Color.clear)
        .task(id: remoteImageWork) {
            let work = remoteImageWork
            remoteImages.setEnabled(work.isEnabled)
            guard work.isEnabled else { return }
            var urls = work.urls
            if urls == nil {
                // スナップショットのない表示では本文を解析し直すため、入力が落ち着くまで待ち、
                // 次の編集で取り消された走査は背景の処理ごと止める。
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                let source = markdown
                let worker = Task.detached(priority: .utility) {
                    RemoteImageStore.referencedURLs(in: source)
                }
                urls = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            }
            guard let urls, !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for url in urls {
                    group.addTask { await remoteImages.load(url) }
                }
            }
        }
        .task(id: citationWatch) {
            let watch = citationWatch
            guard watch.isActive else {
                if citationCatalog != .empty { citationCatalog = .empty }
                return
            }
            // 監視を読み込みより先に始め、読み込み中の保存も変更として受け取る。
            let changes = MarkdownCitationFileMonitor.changes(documentURL: watch.fileURL)
            await reloadCitations(documentURL: watch.fileURL)
            for await _ in changes {
                await reloadCitations(documentURL: watch.fileURL)
            }
        }
        .onDisappear {
            // 閉じたプレビューだけが待っていたローカル画像のデコードは取り消す。
            LocalImageStore.shared.cancelRequests(from: renderCache.imageRequester)
        }
        .onChange(of: localImagePaths) { _, paths in
            // 編集や書類の切り替えで参照されなくなった画像の、待機中のデコードを取り下げる。
            guard let paths else { return }
            LocalImageStore.shared.reconcileRequests(from: renderCache.imageRequester, keepingPaths: paths)
        }
        .sheet(item: $inspectedImage) { item in
            ImageInspectionView(url: item.url)
        }
    }

    private var displayedSource: String { snapshot?.source ?? markdown }

    /// 表示中の本文が参照するローカル画像。スナップショットがない時は求めず、取り下げも行わない。
    private var localImagePaths: Set<String>? {
        guard let snapshot else { return nil }
        return LocalImageStore.localImagePaths(destinations: snapshot.imageDestinations, context: documentContext)
    }

    private func applyNavigation(_ target: PreviewNavigationTarget?, force: Bool, proxy: ScrollViewProxy,
                                 analysis: MarkdownAnalysis, presentationIDs: [Int: String],
                                 index: PreviewScrollIndex?) {
        guard let target, force || settledNavigationSequence != target.sequence else { return }
        if let id = target.presentationID(in: analysis, presentationIDs: presentationIDs, index: index) {
            proxy.scrollTo(id, anchor: .top)
        }
        if target.settles(afterAnalysisChange: !force, displayedSource: displayedSource) {
            settledNavigationSequence = target.sequence
        }
    }

    private func reloadCitations(documentURL: URL?) async {
        let catalog = await Task.detached(priority: .utility) {
            MarkdownCitationCatalog.load(documentURL: documentURL) ?? .empty
        }.value
        guard !Task.isCancelled, catalog != citationCatalog else { return }
        citationCatalog = catalog
    }

    @ViewBuilder
    private func inlineText(_ rendered: NSAttributedString) -> some View {
        // SwiftUI Text drops NSTextAttachment when bridging to AttributedString.
        // Keep formula and image attachments in AppKit, including inside tables and notes.
        if rendered.requiresAppKitText {
            HoverLinkText(rendered: rendered, source: markdown, context: documentContext,
                          loadsExternalPages: loadsExternalLinkPreviews)
        } else {
            Text(AttributedString(rendered)).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func blockText(_ block: MarkdownBlock, in analysis: MarkdownAnalysis) -> some View {
        let rendered = renderCache.render(block, in: analysis, context: renderContext(for: analysis),
            zoom: zoom, remoteRevision: resourceRevision, theme: theme)
        if case let .heading(level) = block.kind {
            inlineText(rendered)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(PreviewAccessibility.headingLabel(level: level, text: rendered.string))
        } else {
            inlineText(rendered)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func taskView(_ block: MarkdownBlock, task: MarkdownTask,
                          in analysis: MarkdownAnalysis) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Toggle(task.isChecked ? "完了" : "未完了", isOn: Binding(
                get: { task.isChecked },
                set: { _ in onToggleTask?(block.sourceRange.location) }
            ))
            .toggleStyle(.checkbox)
            .help(task.isChecked ? "未完了にする" : "完了にする")
            .accessibilityLabel(PreviewAccessibility.taskLabel(task.content))
            .disabled(onToggleTask == nil)

            let rendered = renderCache.render(block, in: analysis, context: renderContext(for: analysis),
                                              zoom: zoom, showsTaskPrefix: false,
                                              remoteRevision: resourceRevision, theme: theme)
            inlineText(rendered)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableView(_ table: MarkdownTable, in analysis: MarkdownAnalysis) -> some View {
        let widths = table.header.indices.map { column in
            let values = [table.header[column]] + table.rows.map { $0[column] }
            return CGFloat(min(360, max(120, (values.map(\.count).max() ?? 0) * 8 + 24)))
        }
        return ScrollView(.horizontal) {
            VStack(spacing: 0) {
                tableRow(table.header, table: table, widths: widths, rowNumber: 0, in: analysis)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, table: table, widths: widths, rowNumber: index + 1, in: analysis)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("表、\(table.header.count) 列、\(table.rows.count + 1) 行")
    }

    private func tableRow(
        _ cells: [String], table: MarkdownTable, widths: [CGFloat], rowNumber: Int,
        in analysis: MarkdownAnalysis
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { column in
                let rendered = renderCache.renderCell(cells[column], in: analysis,
                    context: renderContext, zoom: zoom,
                    remoteRevision: resourceRevision, theme: theme)
                inlineText(rendered)
                    .frame(width: widths[column], alignment: alignment(table.alignments[column]))
                    .padding(8)
                    .frame(minHeight: 34)
                    .background(rowNumber == 0 ? Color.secondary.opacity(0.08) : Color.clear)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    .accessibilityLabel(PreviewAccessibility.tableCellLabel(
                        header: table.header[column], value: cells[column], rowNumber: rowNumber))
                    .accessibilityAddTraits(rowNumber == 0 ? .isHeader : [])
            }
        }
    }

    private func alignment(_ value: MarkdownTable.Alignment) -> Alignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct PreviewBlockOriginsKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] { [:] }

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension NSAttributedString {
    var requiresAppKitText: Bool {
        var found = false
        enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, _, stop in
            if attributes[.link] != nil || attributes[.attachment] != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}

private struct HoverLinkText: NSViewRepresentable {
    @Environment(\.openURL) private var openURL
    let rendered: NSAttributedString
    let source: String
    let context: DocumentContext
    let loadsExternalPages: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HoverPreviewTextView {
        let view = HoverPreviewTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = false
        view.delegate = context.coordinator
        updateNSView(view, context: context)
        return view
    }

    static func dismantleNSView(_ view: HoverPreviewTextView, coordinator: Coordinator) {
        view.cancelHover()
    }

    func updateNSView(_ view: HoverPreviewTextView, context: Context) {
        context.coordinator.onOpenURL = { url in openURL(url) }
        if view.hoverDocumentContext != self.context ||
            view.hoverSource != source ||
            view.loadsExternalLinkPreviews != loadsExternalPages {
            view.cancelHover()
        }
        view.hoverDocumentContext = self.context
        view.hoverSource = source
        view.loadsExternalLinkPreviews = loadsExternalPages
        if !view.attributedString().isEqual(to: rendered) {
            view.textStorage?.setAttributedString(rendered)
            view.cancelHover()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: HoverPreviewTextView,
                      context: Context) -> CGSize? {
        guard let container = view.textContainer, let manager = view.layoutManager else { return nil }
        let width = max(1, proposal.width ?? 500)
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        view.frame.size.width = width
        manager.ensureLayout(for: container)
        let height = manager.usedRect(for: container).height
        return CGSize(width: width, height: max(1, height))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenURL: ((URL) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else {
                return false
            }
            onOpenURL?(url)
            return true
        }
    }
}

enum PreviewAccessibility {
    static func requiresStructuredView(_ blocks: [MarkdownBlock]) -> Bool {
        blocks.contains { block in
            if case .heading = block.kind { return true }
            return block.kind == .table || block.task != nil
        }
    }

    static func headingLabel(level: Int, text: String) -> String {
        String(localized: "見出しレベル \(level)、\(text)")
    }

    static func taskLabel(_ content: String) -> String {
        content.isEmpty ? String(localized: "タスクの完了") : String(localized: "\(content) の完了")
    }

    static func tableCellLabel(header: String, value: String, rowNumber: Int) -> String {
        rowNumber == 0 ? String(localized: "列見出し \(header)") : String(localized: "\(header) 列、\(rowNumber) 行目、\(value)")
    }
}

private struct MarkdownTextPreview: NSViewRepresentable {
    let markdown: String
    let documentContext: DocumentContext
    let imageRequester: LocalImageRequester
    let analysis: MarkdownAnalysis?
    let onOpenHeading: ((String) -> Void)?
    let onOpenDocument: ((URL) -> Void)?
    let zoom: Double
    let remoteRevision: Int
    let loadsExternalLinkPreviews: Bool
    let onInspectImage: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        (scrollView.documentView as? HoverPreviewTextView)?.cancelHover()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Match the source editor: this pane must not paint into the titlebar.
        scrollView.clipsToBounds = true

        let textView = HoverPreviewTextView()
        textView.delegate = context.coordinator
        context.coordinator.onOpenHeading = onOpenHeading
        context.coordinator.onOpenDocument = onOpenDocument
        context.coordinator.onInspectImage = onInspectImage
        context.coordinator.documentContext = documentContext
        textView.hoverDocumentContext = documentContext
        textView.hoverSource = markdown
        textView.loadsExternalLinkPreviews = loadsExternalLinkPreviews
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        scrollView.documentView = textView
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? HoverPreviewTextView else { return }
        context.coordinator.onOpenHeading = onOpenHeading
        context.coordinator.onOpenDocument = onOpenDocument
        context.coordinator.onInspectImage = onInspectImage
        context.coordinator.documentContext = documentContext
        if textView.hoverDocumentContext != documentContext ||
            textView.hoverSource != markdown ||
            textView.loadsExternalLinkPreviews != loadsExternalLinkPreviews {
            textView.cancelHover()
        }
        textView.hoverDocumentContext = documentContext
        textView.hoverSource = markdown
        textView.loadsExternalLinkPreviews = loadsExternalLinkPreviews
        update(textView, coordinator: context.coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenHeading: ((String) -> Void)?
        var onOpenDocument: ((URL) -> Void)?
        var onInspectImage: ((URL) -> Void)?
        var documentContext = DocumentContext(fileURL: nil)
        var renderedSource: String?
        var renderedContext: DocumentContext?
        var renderedZoom: Double?
        var renderedRemoteRevision: Int?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
            if let imageURL = MarkdownImageInspectionLink.destination(url) {
                onInspectImage?(imageURL)
                return true
            }
            if let fileURL = MarkdownAttachmentInspectionLink.localFile(url,
                context: documentContext) {
                onInspectImage?(fileURL)
                return true
            }
            if let fragment = MarkdownHeadingIndex.localFragment(in: url), let onOpenHeading {
                onOpenHeading(fragment)
                return true
            }
            if MarkdownDocumentLink(url: url, context: documentContext) != nil,
               let onOpenDocument {
                onOpenDocument(url)
                return true
            }
            return false
        }
    }

    private func update(_ textView: NSTextView, coordinator: Coordinator) {
        guard coordinator.renderedSource != markdown ||
                coordinator.renderedContext != documentContext ||
                coordinator.renderedZoom != zoom ||
                coordinator.renderedRemoteRevision != remoteRevision else { return }
        let rendered = MarkdownRenderer.$localImageRequester.withValue(imageRequester) {
            analysis.map { MarkdownRenderer.render($0, documentContext: documentContext) }
                ?? MarkdownRenderer.render(markdown, documentContext: documentContext)
        }
        textView.textStorage?.setAttributedString(PreviewTypography.scaled(rendered, by: zoom))
        coordinator.renderedSource = markdown
        coordinator.renderedContext = documentContext
        coordinator.renderedZoom = zoom
        coordinator.renderedRemoteRevision = remoteRevision
    }
}

final class HoverPreviewTextView: NSTextView {
    var hoverDocumentContext = DocumentContext(fileURL: nil)
    var hoverSource = ""
    var loadsExternalLinkPreviews = false
    private let linkHover = MarkdownLinkHoverPopover()
    private var hoverTrackingArea: NSTrackingArea?

    func cancelHover() { linkHover.cancel() }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let storage = textStorage, let layoutManager, let textContainer else {
            linkHover.cancel()
            return
        }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x,
                                     y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else {
            linkHover.cancel()
            return
        }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length,
              let raw = storage.attribute(.link, at: index, effectiveRange: nil),
              let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:)) else {
            linkHover.cancel()
            return
        }
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        guard glyphRect.insetBy(dx: -2, dy: -2).contains(point) else {
            linkHover.cancel()
            return
        }
        linkHover.show(url, relativeTo: glyphRect, of: self,
                       context: hoverDocumentContext, source: hoverSource,
                       loadsExternalPages: loadsExternalLinkPreviews)
    }

    override func mouseExited(with event: NSEvent) {
        linkHover.cancel()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        linkHover.cancel()
        super.mouseDown(with: event)
    }
}

private struct ImageInspectionItem: Identifiable {
    let id = UUID()
    let url: URL
}

enum MarkdownAttachmentInspectionLink {
    static func localFile(_ link: URL, context: DocumentContext) -> URL? {
        guard link.scheme == nil,
              let file = context.resolveLocalResource(link.relativeString),
              !["md", "markdown", "txt"].contains(file.pathExtension.lowercased()),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return nil }
        return file
    }
}

private struct ImageInspectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsOriginalSize = false
    let url: URL

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(url.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                if !url.isFileURL {
                    Toggle("原寸", isOn: $showsOriginalSize)
                        .toggleStyle(.button)
                }
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if url.isFileURL {
                QuickLookImageView(url: url)
            } else if let image = RemoteImageStore.shared.fullImage(for: url) {
                GeometryReader { geometry in
                    let scale = showsOriginalSize ? 1 : min(1,
                        geometry.size.width / max(image.size.width, 1),
                        geometry.size.height / max(image.size.height, 1))
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: image.size.width * scale,
                                   height: image.size.height * scale)
                            .frame(minWidth: geometry.size.width,
                                   minHeight: geometry.size.height)
                    }
                }
            } else {
                ContentUnavailableView("画像を表示できません", systemImage: "photo",
                    description: Text("もう一度プレビューを開いてください。"))
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 480)
    }
}

private struct QuickLookImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero)!
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

@MainActor
final class DetachedPreviewWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var documentURL: URL?
    private var window: NSWindow?

    var isOpen: Bool { window?.isVisible == true }

    func show(document: Binding<MarkdownDocument>, documentURL: URL?,
              settingsStore: EditorSettingsStore, workspaceStore: WorkspaceStore,
              updates: PreviewUpdateController) {
        self.documentURL = documentURL
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let content = DetachedPreviewContent(document: document, manager: self,
            settingsStore: settingsStore, workspaceStore: workspaceStore, updates: updates)
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.title = title
        window.setContentSize(NSSize(width: 760, height: 680))
        window.minSize = NSSize(width: 420, height: 300)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.delegate = self
        window.setFrameAutosaveName("MKTownEditor.detachedPreview")
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func updateDocumentURL(_ url: URL?) {
        documentURL = url
        window?.title = title
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private var title: String {
        String(localized: "プレビュー — \(documentURL?.lastPathComponent ?? String(localized: "無題"))")
    }
}

private struct DetachedPreviewContent: View {
    @Binding var document: MarkdownDocument
    @ObservedObject var manager: DetachedPreviewWindowManager
    @ObservedObject var settingsStore: EditorSettingsStore
    @ObservedObject var workspaceStore: WorkspaceStore
    @ObservedObject var updates: PreviewUpdateController

    var body: some View {
        let dialect = settingsStore.markdownDialect(for: manager.documentURL)
        let presentation = PreviewPresentation(
            snapshot: updates.state.isPaused ? updates.snapshot : nil,
            requestedSource: updates.state.displayedSource ?? document.text,
            currentSource: document.text, dialect: dialect)
        VStack(spacing: 0) {
            PreviewUpdateControls(updates: updates, source: document.text, dialect: dialect)
            MarkdownPreview(markdown: presentation.source,
                            documentContext: DocumentContext(fileURL: manager.documentURL,
                                attachmentDirectory: settingsStore.attachmentDirectory(for: manager.documentURL),
                                markdownDialect: dialect),
                            snapshot: presentation.snapshot,
                            usesSharedAnalysis: updates.state.isPaused,
                            workspaceDocumentURLs: workspaceStore.documentURLs,
                            workspaceContentRevisions: workspaceStore.contentRevisions,
                            workspaceDiskRevision: workspaceStore.rootURL == nil ? nil : workspaceStore.fileSystemRevision,
                            workspaceIndex: workspaceStore.documentIndex,
                            loadWorkspaceOpenBuffers: workspaceStore.rootURL.map { root in
                                { requested in try workspaceStore.openBufferSnapshots(under: root, including: requested) }
                            },
                            showsFrontMatter: settingsStore.app.showsFrontMatterInPreview ?? false,
                            zoom: settingsStore.zoom(for: .preview),
                            loadsRemoteImages: settingsStore.app.loadsRemoteImages ?? false,
                            theme: settingsStore.app.previewTheme ?? .system,
                            bodyWidth: settingsStore.app.previewBodyWidth ?? 900)
        }
        .frame(minWidth: 420, minHeight: 300)
        // This window is not a SwiftUI scene, so the View menu command cannot reach it; it keeps
        // its own pause button while the update bar is hidden.
        .overlay(alignment: .topTrailing) {
            if !updates.state.isPaused {
                Button {
                    updates.pause(source: document.text, dialect: dialect)
                } label: {
                    Image(systemName: "pause.circle")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(10)
                .help("プレビューの自動更新を一時停止")
                .accessibilityLabel("プレビューの自動更新を一時停止")
            }
        }
    }
}

struct PreviewUpdateState {
    private(set) var currentRevision = 1
    private(set) var displayedRevision: Int?
    private(set) var displayedSource: String?

    var isPaused: Bool { displayedSource != nil }
    var isStale: Bool { isPaused && displayedRevision != currentRevision }

    mutating func sourceChanged() { currentRevision += 1 }

    mutating func pause(at source: String) {
        displayedSource = source
        displayedRevision = currentRevision
    }

    mutating func refresh(to source: String) {
        guard isPaused else { return }
        displayedSource = source
        displayedRevision = currentRevision
    }

    mutating func resume() {
        displayedSource = nil
        displayedRevision = nil
    }
}

@MainActor
final class PreviewUpdateController: ObservableObject {
    @Published private(set) var state = PreviewUpdateState()
    @Published private(set) var snapshot: DocumentSnapshot?
    private var generation = 0
    private var task: Task<Void, Never>?

    func sourceChanged() { state.sourceChanged() }

    func pause(source: String, dialect: MarkdownDialect = .extended,
               preferredSnapshot: DocumentSnapshot? = nil) {
        state.pause(at: source)
        capture(source: source, dialect: dialect, preferredSnapshot: preferredSnapshot)
    }

    func refresh(source: String, dialect: MarkdownDialect = .extended,
                 preferredSnapshot: DocumentSnapshot? = nil) {
        guard state.isPaused else { return }
        state.refresh(to: source)
        capture(source: source, dialect: dialect, preferredSnapshot: preferredSnapshot)
    }

    func togglePause(source: String, dialect: MarkdownDialect = .extended,
                     preferredSnapshot: DocumentSnapshot? = nil) {
        if state.isPaused { resume() }
        else { pause(source: source, dialect: dialect, preferredSnapshot: preferredSnapshot) }
    }

    func resume() {
        state.resume()
        generation += 1
        task?.cancel()
        task = nil
        snapshot = nil
    }

    private func capture(source: String, dialect: MarkdownDialect,
                         preferredSnapshot: DocumentSnapshot?) {
        generation += 1
        let requestedGeneration = generation
        task?.cancel()
        if preferredSnapshot?.source == source && preferredSnapshot?.dialect == dialect {
            snapshot = preferredSnapshot
            task = nil
            return
        }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = DocumentSnapshot(source: source, dialect: dialect)
            await self?.publish(result, generation: requestedGeneration)
        }
    }

    private func publish(_ result: DocumentSnapshot, generation requestedGeneration: Int) {
        guard generation == requestedGeneration, state.displayedSource == result.source else { return }
        snapshot = result
        task = nil
    }
}

/// Shown only while automatic preview updates are paused. Revision counters are internal and
/// are described to the user as "up to date" or "changes not shown yet" instead (#24).
struct PreviewUpdateControls: View {
    @ObservedObject var updates: PreviewUpdateController
    let source: String
    var preferredSnapshot: DocumentSnapshot?
    var dialect: MarkdownDialect = .extended

    static func statusText(for state: PreviewUpdateState) -> String? {
        guard state.isPaused else { return nil }
        return state.isStale ? String(localized: "プレビューは一時停止中 — 未反映の変更あり")
            : String(localized: "プレビューは一時停止中 — 最新")
    }

    var body: some View {
        if let status = Self.statusText(for: updates.state) {
            HStack(spacing: 10) {
                Label(status, systemImage: "pause.circle")
                    .foregroundStyle(updates.state.isStale ? .orange : .secondary)
                Spacer()
                Button("更新", systemImage: "arrow.clockwise") {
                    updates.refresh(source: source, dialect: dialect,
                                    preferredSnapshot: preferredSnapshot)
                }
                .disabled(!updates.state.isStale)
                .help("一時停止したまま最新の内容を表示")
                Button("再開", systemImage: "play.fill") {
                    updates.resume()
                }
                .help("プレビューの自動更新を再開")
            }
            .font(.caption)
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .accessibilityElement(children: .contain)
        }
    }
}

@MainActor
enum MarkdownCodeCopy {
    @discardableResult
    static func copy(_ block: MarkdownBlock,
                     to pasteboard: NSPasteboard = .general) -> Bool {
        guard block.kind == .codeBlock else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(block.content, forType: .string)
    }
}
