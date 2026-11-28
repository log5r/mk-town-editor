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
        source == nil || MarkdownTextFormat.identicalText(source, displayedSource)
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
    @StateObject private var userScrollMonitor = PreviewUserScrollMonitor()
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
    var formatsFrontMatter = false
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
        if let snapshot, MarkdownTextFormat.identicalText(snapshot.source, markdown) {
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
                                FrontMatterPreviewView(frontMatter: frontMatter,
                                    formatsProperties: formatsFrontMatter, theme: theme, zoom: zoom)
                                    .padding(.bottom, 16)
                            }
                            ForEach(layout.visibleBlocks.map { block in
                                PreviewBlockRow(block: block, id: presentationIDs[block.id] ?? String(block.id))
                            }) { row in
                                let block = row.block
                                let matchesSearch = isSearchMatch(block)
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
                                                .font(PreviewSupplementaryFont.body(zoom: zoom))
                                                .accessibilityHidden(true)
                                            calloutContent(block, in: analysis)
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
                                            onOpen: onOpenEmbeddedDocument,
                                            preservesSoftLineBreaks: documentContext.preservesSoftLineBreaks,
                                            zoom: zoom)
                                    } else if let media = MarkdownMedia(block, dialect: analysis.dialect) {
                                        MarkdownMediaPreview(media: media, documentContext: documentContext)
                                    } else if documentContext.markdownDialect == .extended,
                                              block.kind == .paragraph,
                                              let formula = MarkdownMath.displayFormula(block.content),
                                              renderCache.canRenderDisplayFormula(formula) {
                                        HStack {
                                            MarkdownMathView(formula: formula, zoom: zoom)
                                                .accessibilityLabel(formula.latex)
                                            if let target = analysis.crossReferences.target(forBlockID: block.id) {
                                                Text(target.label)
                                                    .font(PreviewSupplementaryFont.body(zoom: zoom))
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                    } else if let table = block.table {
                                        VStack(alignment: .leading) {
                                            if let target = analysis.crossReferences.target(forBlockID: block.id) {
                                                Text(target.label).font(PreviewSupplementaryFont.caption(zoom: zoom))
                                                    .foregroundStyle(.secondary)
                                            }
                                            tableView(table, sourceRange: block.sourceRange, in: analysis)
                                        }
                                    } else if block.kind == .blank {
                                        Text(" ").frame(height: 12)
                                    } else if MermaidDiagram.isDiagram(block) {
                                        MermaidDiagramView(source: block.content)
                                    } else if block.kind == .codeBlock,
                                              let kind = ExternalDiagramKind(language: block.codeLanguage) {
                                        ExternalDiagramView(source: block.content, kind: kind)
                                    } else if block.kind == .codeBlock {
                                        codeBlockView(block, in: analysis, isSearchMatch: matchesSearch)
                                    } else if let task = block.task {
                                        taskView(block, task: task, in: analysis)
                                    } else {
                                        blockText(block, in: analysis, parent: layout.parent(of: block))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(matchesSearch ? PreviewCodeBlockStyle.searchMatchTint : Color.clear)
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
                                Text("脚注").font(PreviewSupplementaryFont.headline(zoom: zoom))
                                    .padding(.top, 20)
                                ForEach(analysis.footnotes.entries, id: \.number) { note in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(note.number).").font(PreviewSupplementaryFont.body(zoom: zoom))
                                        // 表のセルと同じ描画で、表示倍率とテーマを本文と同じく反映する。
                                        inlineText(renderCache.renderCell(note.content, in: analysis,
                                            context: renderContext, zoom: zoom,
                                            remoteRevision: resourceRevision, theme: theme))
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
                                Text("参考文献").font(PreviewSupplementaryFont.headline(zoom: zoom)).padding(.top, 20)
                                ForEach(Array(citationCatalog.entries.enumerated()), id: \.element.key) { index, entry in
                                    Text(verbatim: "\(index + 1). \(entry.bibliographyText)")
                                        .font(PreviewSupplementaryFont.body(zoom: zoom))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: CGFloat(bodyWidth), alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .background(PreviewUserScrollObserver(monitor: userScrollMonitor,
                            identity: analysis.identity,
                            onVisibleBlockChange: onVisibleBlockChange))
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
                        userScrollMonitor.record(origins: origins, identity: analysis.identity)
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
        .background(theme.previewBackground.map { Color(nsColor: $0) } ?? Color.clear)
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

    /// ブロックの文字列を `NSTextView`（`HoverLinkText`）で描く。
    /// SwiftUI の `Text` は使わない。`Text` は段落スタイルの字下げと行間、添付画像、リンクの文字色を無視する
    /// （docs/swiftui-caused-bugs.md）。性能は docs/preview-text-backend-performance.md で確かめた。
    ///
    /// - Parameter sourceRange: 文脈メニューの「原文へ移動」で示す原文の範囲。右クリックは `NSTextView` が受け取り、
    ///   行に付けた SwiftUI の文脈メニューが出ないため、ここから渡す。ブロックに属さない箇所（脚注など）では `nil`。
    @ViewBuilder
    private func inlineText(_ rendered: NSAttributedString, sourceRange: NSRange? = nil) -> some View {
        if PreviewAppKitIndent.containsListIndent(rendered) || PreviewAppKitIndent.containsQuotePrefix(rendered) {
            // 複数のブロックをまとめた文字列（コールアウト）の入れ子のリストと引用。
            // 字下げと引用の縦線を行の幅いっぱいで描く。字下げは文字と同じく表示倍率で広げる。
            HoverLinkText(rendered: PreviewAppKitIndent.aligned(rendered, indentScale: CGFloat(zoom)),
                          source: markdown,
                          context: documentContext, loadsExternalPages: loadsExternalLinkPreviews,
                          linkAttributes: PreviewLinkStyle.textViewAttributes(for: theme),
                          onRevealSource: revealAction(for: sourceRange))
        } else {
            // 文字の幅に合わせ、表のセルの寄せや、脚注の後ろに置くボタンの位置を周りのレイアウトに任せる。
            // 添付画像を含む文字列は行の幅いっぱいで描く。画像は行の残りの幅に合わせて大きさを決めるため
            // （`MarkdownImageAttachment`）、測った幅に置き直すと画像が縮む。
            let (hasLink, hasAttachment) = rendered.linkAndAttachmentPresence
            let text = HoverLinkText(rendered: rendered, source: markdown, context: documentContext,
                                     loadsExternalPages: loadsExternalLinkPreviews,
                                     linkAttributes: PreviewLinkStyle.textViewAttributes(for: theme),
                                     hugsContent: !hasAttachment,
                                     onRevealSource: revealAction(for: sourceRange))
            if hasLink || hasAttachment {
                // リンクを1つずつたどれるよう、`NSTextView` のアクセシビリティ要素をそのまま公開する。
                text
            } else {
                // `NSTextView` は編集できなくても「テキスト入力領域」として公開され、呼び出し側が付ける
                // 見出しの特性やラベル（`accessibilityAddTraits`・`accessibilityLabel`）も届かない。
                // リンクのない文字列は静的なテキストとして公開し、呼び出し側の指定が効くようにする。
                text.accessibilityRepresentation { Text(rendered.string) }
            }
        }
    }

    /// `NSTextView` の文脈メニューの「原文へ移動」。行の SwiftUI の文脈メニューと同じ範囲を示す。
    private func revealAction(for sourceRange: NSRange?) -> (() -> Void)? {
        guard let sourceRange, let onRevealSource else { return nil }
        return { onRevealSource(sourceRange) }
    }

    /// コールアウトの中身。直下のコードブロックは文字列に含めず、通常のコードブロックと同じ枠で囲む。
    /// 文章の部分は描画結果のキャッシュを通らないため、ここで表示倍率を反映する（コードブロックは `blockText` が反映する）。
    private func calloutContent(_ block: MarkdownBlock, in analysis: MarkdownAnalysis) -> some View {
        let segments = MarkdownRenderer.$localImageRequester.withValue(renderCache.imageRequester) {
            MarkdownRenderer.renderCalloutSegments(block, in: analysis,
                                                   documentContext: renderContext(for: analysis),
                                                   quotesText: false)
        }
        // 縦線は引用記号（`│`）の文字ではなく1本の図形で引く。文字で描くと行間で途切れ、破線に見える。
        return HStack(alignment: .top, spacing: 0) {
            PreviewQuoteBar()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(segments.indices, id: \.self) { index in
                    switch segments[index] {
                    case let .text(rendered):
                        inlineText(PreviewTypography.scaled(rendered, by: zoom), sourceRange: block.sourceRange)
                    case let .codeBlock(code):
                        codeBlockView(code, in: analysis, isSearchMatch: isSearchMatch(code))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 縦線は提案された高さをすべて取るため、行の高さを中身の高さに合わせる。
        .fixedSize(horizontal: false, vertical: true)
    }

    private func isSearchMatch(_ block: MarkdownBlock) -> Bool {
        searchRange.map { NSLocationInRange($0.location, block.sourceRange) } == true
    }

    private func codeBlockView(_ block: MarkdownBlock, in analysis: MarkdownAnalysis,
                               isSearchMatch: Bool) -> some View {
        PreviewCodeBlockFrame(theme: theme, isSearchMatch: isSearchMatch,
                              onCopy: { _ = MarkdownCodeCopy.copy(block) }) {
            blockText(block, in: analysis)
        }
    }

    @ViewBuilder
    private func blockText(_ block: MarkdownBlock, in analysis: MarkdownAnalysis,
                           parent: MarkdownBlock? = nil) -> some View {
        let rendered = renderCache.render(block, in: analysis, context: renderContext(for: analysis),
            zoom: zoom, remoteRevision: resourceRevision, theme: theme)
        if case let .heading(level) = block.kind {
            inlineText(rendered, sourceRange: block.sourceRange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(PreviewAccessibility.headingLabel(level: level, text: rendered.string))
        } else if Self.isListItem(block) {
            // 行頭記号と本文を1つの選択面に保ったまま字下げするため、段落スタイルの字下げを位置に直して描く。
            HoverLinkText(rendered: PreviewAppKitIndent.aligned(rendered, indentScale: CGFloat(zoom)),
                          source: markdown, context: documentContext,
                          loadsExternalPages: loadsExternalLinkPreviews,
                          linkAttributes: PreviewLinkStyle.textViewAttributes(for: theme),
                          onRevealSource: revealAction(for: block.sourceRange))
            .frame(maxWidth: .infinity, alignment: .leading)
            // `NSTextView` は最後の行の後ろの行間を高さに含めない。項目ごとに描くと項目の間が詰まるため補い、
            // 1つの文字列で描くリスト（コールアウトの中など）と同じ間隔にする。
            .padding(.bottom, PreviewListIndent.trailingSpacing(of: rendered))
        } else {
            // 項目の続きの段落は、字下げを行の余白で表す。
            inlineText(PreviewListIndent.withoutIndent(rendered), sourceRange: block.sourceRange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, continuationIndent(of: rendered, parent: parent, in: analysis))
        }
    }

    private static func isListItem(_ block: MarkdownBlock) -> Bool {
        switch block.kind {
        case .unorderedList, .orderedList: true
        default: false
        }
    }

    /// 項目の続きの段落の左端。親の項目の本文の左端にそろえる。
    /// 幅の広い行頭記号で項目の本文が右へずれた場合も、`PreviewAppKitIndent.itemBodyIndent` で同じ位置を求める。
    private func continuationIndent(of rendered: NSAttributedString, parent: MarkdownBlock?,
                                    in analysis: MarkdownAnalysis) -> CGFloat {
        let scale = CGFloat(zoom)
        let nominal = (PreviewAppKitIndent.contentStyle(of: rendered,
            in: NSRange(location: 0, length: rendered.length))?.headIndent ?? 0) * scale
        // タスクはチェックボックスで描き、本文の位置が行頭記号の幅で決まらない。
        guard nominal > 0, let parent, Self.isListItem(parent), parent.task == nil else { return nominal }
        let parentRendered = renderCache.render(parent, in: analysis, context: renderContext(for: analysis),
                                                zoom: zoom, remoteRevision: resourceRevision, theme: theme)
        return PreviewAppKitIndent.itemBodyIndent(parentRendered, indentScale: scale) ?? nominal
    }

    private func taskView(_ block: MarkdownBlock, task: MarkdownTask,
                          in analysis: MarkdownAnalysis) -> some View {
        let rendered = renderCache.render(block, in: analysis, context: renderContext(for: analysis),
                                          zoom: zoom, showsTaskPrefix: false,
                                          remoteRevision: resourceRevision, theme: theme)
        // チェックボックスを行頭記号の位置に置き、入れ子の深さを行の余白で表す。
        // 位置は深さから求める。本文が空のタスクは描画結果が空になり、字下げを読み取れないため。
        return HStack(alignment: .top, spacing: 8) {
            Toggle(task.isChecked ? "完了" : "未完了", isOn: Binding(
                get: { task.isChecked },
                set: { _ in onToggleTask?(block.sourceRange.location) }
            ))
            .toggleStyle(.checkbox)
            .help(task.isChecked ? "未完了にする" : "完了にする")
            .accessibilityLabel(PreviewAccessibility.taskLabel(task.content))
            .disabled(onToggleTask == nil)

            // 番号付きのタスクの番号（`1.  `）と本文は、1つの選択面に置く。
            inlineText(PreviewListIndent.withoutIndent(rendered), sourceRange: block.sourceRange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, PreviewListIndent.taskCheckboxIndent(for: block) * CGFloat(zoom))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableView(_ table: MarkdownTable, sourceRange: NSRange,
                           in analysis: MarkdownAnalysis) -> some View {
        let widths = table.header.indices.map { column in
            let values = [table.header[column]] + table.rows.map { $0[column] }
            return CGFloat(min(360, max(120, (values.map(\.count).max() ?? 0) * 8 + 24)))
        }
        return ScrollView(.horizontal) {
            VStack(spacing: 0) {
                tableRow(table.header, table: table, widths: widths, rowNumber: 0, sourceRange: sourceRange,
                         in: analysis)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, table: table, widths: widths, rowNumber: index + 1, sourceRange: sourceRange,
                             in: analysis)
                }
            }
            // セルは右と下の線だけを引く。表の上と左の線をここで足し、どの線も同じ太さにする。
            .overlay(alignment: .top) { PreviewTableStyle.horizontalBorder }
            .overlay(alignment: .leading) { PreviewTableStyle.verticalBorder }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("表、\(table.header.count) 列、\(table.rows.count + 1) 行")
    }

    private func tableRow(
        _ cells: [String], table: MarkdownTable, widths: [CGFloat], rowNumber: Int, sourceRange: NSRange,
        in analysis: MarkdownAnalysis
    ) -> some View {
        // 折り返したセルがあっても、行のすべてのセルを同じ高さにして縦線をつなげる。
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { column in
                let rendered = renderCache.renderCell(cells[column], in: analysis,
                    context: renderContext, zoom: zoom,
                    remoteRevision: resourceRevision, theme: theme)
                inlineText(rendered, sourceRange: sourceRange)
                    .frame(width: widths[column], alignment: alignment(table.alignments[column]))
                    .padding(8)
                    .frame(minHeight: 34)
                    .frame(maxHeight: .infinity)
                    .background(rowNumber == 0 ? PreviewTableStyle.headerFill : Color.clear)
                    .overlay(alignment: .trailing) { PreviewTableStyle.verticalBorder }
                    .overlay(alignment: .bottom) { PreviewTableStyle.horizontalBorder }
                    .accessibilityLabel(PreviewAccessibility.tableCellLabel(
                        header: table.header[column], value: cells[column], rowNumber: rowNumber))
                    .accessibilityAddTraits(rowNumber == 0 ? .isHeader : [])
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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

extension NSAttributedString {
    /// リンクと添付（画像、数式）を含むか。
    var linkAndAttachmentPresence: (link: Bool, attachment: Bool) {
        var result = (link: false, attachment: false)
        enumerateAttributes(in: NSRange(location: 0, length: length)) { attributes, _, stop in
            if attributes[.link] != nil { result.link = true }
            if attributes[.attachment] != nil { result.attachment = true }
            if result.link && result.attachment { stop.pointee = true }
        }
        return result
    }
}

/// `NSTextView` で描く選択可能な文字列。リンクのホバー表示を持つ。
/// 構造化プレビューの見出し、段落、リスト項目、表のセル、コールアウト、脚注と、埋め込み文書をこれで描く。
/// 行の余白（`lineFragmentPadding`）は持たず、周りの図形（引用の縦線など）と左端をそろえる。
struct HoverLinkText: NSViewRepresentable {
    @Environment(\.openURL) private var openURL
    let rendered: NSAttributedString
    let source: String
    let context: DocumentContext
    let loadsExternalPages: Bool
    var linkAttributes = PreviewLinkStyle.textViewAttributes(for: .system)
    /// 真なら、提案された幅で折り返したうえで、文字が実際に使った幅をビューの幅にする（`Text` と同じ決め方）。
    /// 偽なら、提案された幅いっぱいを使う。字下げや引用の縦線を行の幅で描く文字列に使う。
    var hugsContent = false
    /// 文脈メニューの「原文へ移動」。`NSTextView` は右クリックを受け取り、行に付けた SwiftUI の文脈メニューを出さないため。
    var onRevealSource: (() -> Void)?

    /// 幅の指定がない提案で、折り返さない幅を求めるときの上限。
    private static let unboundedWidth: CGFloat = 100_000

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HoverPreviewTextView {
        let view = HoverPreviewTextView()
        view.textContainer?.lineFragmentPadding = 0
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        // 文字は、SwiftUI が決めたビューの幅で折り返す（`hugsContent` によらない）。
        // 行の幅いっぱいを使う場合、`sizeThatFits` は尋ねられた幅にコンテナを合わせる。`LazyVStack` は置いた後の
        // 先頭の行を幅の指定のない提案（500）で測り直すことがあり、従わせないとコンテナの幅が置かれた幅と食い違う（#102）。
        view.textContainer?.widthTracksTextView = true
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
            !MarkdownTextFormat.identicalText(view.hoverSource, source) ||
            view.loadsExternalLinkPreviews != loadsExternalPages {
            view.cancelHover()
        }
        view.hoverDocumentContext = self.context
        view.hoverSource = source
        view.loadsExternalLinkPreviews = loadsExternalPages
        view.linkTextAttributes = linkAttributes
        view.revealSource = onRevealSource
        // `NSTextStorage` はフォントを置き換えるため、ビューの文字列は渡した文字列と等しくならないことがある。
        // 渡した文字列を覚えておいて比べ、更新のたびに同じ内容を入れ直さないようにする。
        if !(view.appliedRendered?.isEqual(to: rendered) ?? false) {
            view.textStorage?.setAttributedString(rendered)
            view.appliedRendered = rendered
            view.cancelHover()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: HoverPreviewTextView,
                      context: Context) -> CGSize? {
        guard let container = view.textContainer, let manager = view.layoutManager else { return nil }
        guard hugsContent else {
            // 提案された幅いっぱいを使う。表示中のビューのコンテナで測り、同じ幅に置かれたときはこのレイアウトをそのまま使う。
            // 別の幅に置かれた場合は、コンテナがビューの幅に従ってレイアウトし直す（`widthTracksTextView`）。
            let width = max(1, proposal.width ?? 500)
            container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            view.frame.size.width = width
            manager.ensureLayout(for: container)
            let height = manager.usedRect(for: container).height
            return CGSize(width: width, height: max(1, height))
        }
        // 幅の指定がない（または無限の）提案では、折り返さない幅を返す。
        let proposed = proposal.width ?? .infinity
        let limit = proposed.isFinite ? max(1, proposed) : Self.unboundedWidth
        return context.coordinator.huggedSize(of: view, limit: limit, isUnbounded: !proposed.isFinite)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenURL: ((URL) -> Void)?
        private var measuredText: NSAttributedString?
        private var measuredSizes: [CGFloat: CGSize] = [:]

        /// 幅 `limit` で折り返したときに文字が使う大きさ。SwiftUI は同じ提案で何度も尋ねるため、文字列が変わるまで覚えておく。
        /// 測るのは `NSTextView` が持つ文字列のほう。`NSTextStorage` は日本語などのフォントを置き換えるため、
        /// 渡した文字列で測ると幅が食い違い、返した幅に置かれたビューで折り返しの位置が変わる。
        /// 覚える単位は `appliedRendered`（ビューへ最後に入れた文字列）。内容が変わったときだけ入れ替わる。
        @MainActor func huggedSize(of view: HoverPreviewTextView, limit: CGFloat, isUnbounded: Bool) -> CGSize {
            if measuredText !== view.appliedRendered {
                measuredText = view.appliedRendered
                measuredSizes = [:]
            }
            if let size = measuredSizes[limit] { return size }
            let used = HoverLinkTextMeasurer.usedRect(of: view.attributedString(), width: limit)
            // 幅の上限がないときは文字の幅そのものを返す。右から左の段落は行の右端に寄るため、右端の位置では測れない。
            // 上限があるときは、端数を切り上げ、返した幅で置かれたときに同じ位置で折り返すようにする。
            let width = isUnbounded ? used.width.rounded(.up) : min(limit, used.maxX.rounded(.up))
            let size = CGSize(width: max(1, width), height: max(1, used.height))
            // ウインドウの大きさを変えている間は幅が次々に変わる。覚える数を抑える。
            if measuredSizes.count >= 16 { measuredSizes = [:] }
            measuredSizes[limit] = size
            return size
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else {
                return false
            }
            onOpenURL?(url)
            return true
        }
    }
}

/// `HoverLinkText` の文字が使う大きさを、表示中の `NSTextView` とは別のレイアウトで測る。
/// 表示中のビューのコンテナで測ると、SwiftUI が試しに尋ねた幅（0や無限）のレイアウトがビューに残る。
/// また、一度置かれたビューでは `usedRect` が文字の幅ではなくコンテナの幅を返した（macOS 27 で確認）。
@MainActor
enum HoverLinkTextMeasurer {
    private static let storage = NSTextStorage()
    private static let container: NSTextContainer = {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        return container
    }()
    private static let manager: NSLayoutManager = {
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return manager
    }()

    static func usedRect(of text: NSAttributedString, width: CGFloat) -> CGRect {
        _ = manager
        storage.setAttributedString(text)
        container.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        storage.setAttributedString(NSAttributedString())
        return used
    }
}

/// プレビューのリンクの色。
/// `NSTextView` は `linkTextAttributes` でリンクを描き、文字列に付けた文字色を無視する。
/// テーマのリンク色は文字列の属性に加えて、ここから描画へ渡す。
enum PreviewLinkStyle {
    static func textViewAttributes(for theme: PreviewTheme) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: theme.linkColor ?? NSColor.linkColor,
         .underlineStyle: NSUnderlineStyle.single.rawValue,
         .cursor: NSCursor.pointingHand]
    }
}

/// プレビューのコードブロックの枠の寸法と色。
/// 背景と境界線は文字色を薄く重ねて作り、システム・紙・拡張テーマのどの背景でも本文から区別できるようにする。
enum PreviewCodeBlockStyle {
    static let cornerRadius: CGFloat = 8
    static let padding: CGFloat = 12
    static let copyButtonInset: CGFloat = 20
    static let searchMatchTint = Color.accentColor.opacity(0.12)

    /// 枠の面に下から順に塗る色。テーマがコード背景を定めていればそれを使い、システムでは文字色を 5% 重ねた面にする。
    /// 枠の面は不透明になり得るため、検索の一致は行の背景とは別に面の上へ重ねる。
    static func fillLayers(for theme: PreviewTheme, isSearchMatch: Bool) -> [Color] {
        [theme.codeBackground.map { Color(nsColor: $0) } ?? Color.primary.opacity(0.05)] +
            (isSearchMatch ? [searchMatchTint] : [])
    }

    /// コピーボタンの色。ボタンはコード背景の上にあるため、テーマがあればコード背景とのコントラストを検証済みのコード色を使う。
    /// システム配色では `nil` を返し、ボタンの標準の色にする。
    static func copyButtonColor(for theme: PreviewTheme) -> Color? {
        theme.codeColor.map { Color(nsColor: $0) }
    }

    static func copyButton(theme: PreviewTheme = .system, action: @escaping () -> Void) -> some View {
        Button("コードをコピー", systemImage: "doc.on.doc", action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(copyButtonColor(for: theme).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .help("フェンスを除いたコード本文をコピー")
    }
}

/// プレビューのコードブロックを、背景を塗った角丸の枠で囲み、右上にコピーボタンを置く。
struct PreviewCodeBlockFrame<Content: View>: View {
    var theme: PreviewTheme
    var isSearchMatch = false
    var onCopy: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PreviewCodeBlockStyle.cornerRadius, style: .continuous)
        // ボタンを重ねず同じ ZStack に置き、空のコードブロックでも枠の高さがボタンを収める。
        ZStack(alignment: .topTrailing) {
            content
                // 右上のコピーボタンと1行目が重ならないよう、右側に余白を取る。
                .padding(.trailing, PreviewCodeBlockStyle.copyButtonInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            PreviewCodeBlockStyle.copyButton(theme: theme, action: onCopy)
        }
        .padding(PreviewCodeBlockStyle.padding)
        .background {
            ZStack {
                ForEach(Array(PreviewCodeBlockStyle.fillLayers(for: theme, isSearchMatch: isSearchMatch)
                    .enumerated()), id: \.offset) { _, color in
                    shape.fill(color)
                }
            }
        }
        .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

/// 引用の縦線。引用記号（`│  `）を文字で描く箇所と同じ位置・幅・色で、行間で途切れない1本の線を引く。
struct PreviewQuoteBar: View {
    /// 線の左の余白・線の幅・本文までの余白。合計は引用記号（`│  `）の幅にそろえる。
    static let leading: CGFloat = 1
    static let lineWidth: CGFloat = 1
    static let trailing: CGFloat = 10

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .tertiaryLabelColor))
            .frame(width: Self.lineWidth)
            .padding(.leading, Self.leading)
            .padding(.trailing, Self.trailing)
            .accessibilityHidden(true)
    }
}

/// プレビューの表の罫線と見出し行の色。
/// 罫線は文字色を薄く重ねて作り、明暗どちらの背景でも表の区切りが読み取れる濃さにする。
enum PreviewTableStyle {
    static let borderOpacity = 0.3
    static let borderWidth: CGFloat = 1
    static let borderColor = Color.primary.opacity(borderOpacity)
    static let headerFill = Color.secondary.opacity(0.08)

    static var horizontalBorder: some View {
        Rectangle().fill(borderColor).frame(height: borderWidth).accessibilityHidden(true)
    }

    static var verticalBorder: some View {
        Rectangle().fill(borderColor).frame(width: borderWidth).accessibilityHidden(true)
    }
}

/// 文書を文字列1つで描く箇所（埋め込み文書）のコードブロック。
/// 前後の文章の引用記号（`│  `）と同じ位置に引用の深さだけ縦線を引き、`PreviewCodeBlockFrame` で囲む。
/// 埋め込み文書の文字はテーマの色を当てないため、枠もシステム配色にする。
struct PreviewQuotedCodeBlock<Content: View>: View {
    var quoteDepth: Int
    var onCopy: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<quoteDepth, id: \.self) { _ in
                PreviewQuoteBar()
            }
            PreviewCodeBlockFrame(theme: .system, onCopy: onCopy) {
                content
            }
        }
        // 縦線は提案された高さをすべて取るため、行の高さを枠の高さに合わせる。
        .fixedSize(horizontal: false, vertical: true)
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
            !MarkdownTextFormat.identicalText(textView.hoverSource, markdown) ||
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
        guard !MarkdownTextFormat.identicalText(coordinator.renderedSource, markdown) ||
                coordinator.renderedContext != documentContext ||
                coordinator.renderedZoom != zoom ||
                coordinator.renderedRemoteRevision != remoteRevision else { return }
        let rendered = MarkdownRenderer.$localImageRequester.withValue(imageRequester) {
            analysis.map { MarkdownRenderer.render($0, documentContext: documentContext) }
                ?? MarkdownRenderer.render(markdown, documentContext: documentContext)
        }
        // 引用の中のリストの字下げと、幅の広い行頭記号の下の本文の位置をそろえる。
        // 字下げは構造化プレビューのリスト項目と同じく、文字と同じ倍率で広げる。
        textView.textStorage?.setAttributedString(PreviewTypography.scaledAndAligned(rendered, by: zoom))
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

    /// 設定すると、文脈メニューの先頭に「原文へ移動」を加える。
    var revealSource: (() -> Void)?

    /// `HoverLinkText` が最後に入れた文字列。`attributedString()` はフォントの置き換えで変わるため、比較にはこれを使う。
    var appliedRendered: NSAttributedString?

    /// 文字列が引用の縦線（`PreviewQuoteBars`）を含むか。文字列が変わるまで覚えておく。
    fileprivate var hasQuoteBars: Bool?
    /// 引用記号の文字を隠す一時属性を、今の文字列に合わせて付け直す必要があるか。文字列が変わると立てる。
    fileprivate var quoteGlyphsNeedUpdate = true
    /// 一時属性を付けたことがあるか。付けた後に引用のない文字列へ変わったら、古い一時属性を外す。
    private var hasHiddenQuoteGlyphs = false

    private func containsQuoteBars() -> Bool {
        // 文字列の変更を受け取り、覚えた結果を捨てる。
        if textStorage?.delegate == nil { textStorage?.delegate = self }
        if let hasQuoteBars { return hasQuoteBars }
        let result = textStorage.map { PreviewQuoteBars.containsBars($0) } ?? false
        hasQuoteBars = result
        return result
    }

    /// 引用記号の縦線の文字を、表示のときだけ透明にする。文字列（`textStorage`）は変えない。
    /// `layoutManager` に触れると TextKit 1 に切り替わるため、引用の縦線を含む文字列か、
    /// すでに一時属性を付けた（切り替わった）後に限る。
    private func updateQuoteGlyphs() {
        let hasBars = containsQuoteBars()
        guard quoteGlyphsNeedUpdate, hasBars || hasHiddenQuoteGlyphs, let layoutManager else { return }
        quoteGlyphsNeedUpdate = false
        if hasBars {
            PreviewQuoteBars.hideGlyphs(in: layoutManager)
            hasHiddenQuoteGlyphs = true
        } else if let textStorage {
            layoutManager.removeTemporaryAttribute(.foregroundColor,
                                                   forCharacterRange: NSRange(location: 0, length: textStorage.length))
            hasHiddenQuoteGlyphs = false
        }
    }

    override func viewWillDraw() {
        // 縦線は `NSLayoutManager` の行の位置から求める。描画の途中でレイアウトの方式が切り替わらないよう、
        // 先に用意し、引用記号の文字を隠す一時属性も付けておく。
        updateQuoteGlyphs()
        super.viewWillDraw()
    }

    /// 縦線は文字の背景として描く。`draw(_:)` を上書きすると `NSTextView` は初めから TextKit 1 で作られ、
    /// 引用を含まない文字列でも TextKit 2 を使えなくなるため。記号の文字は透明にしてあり、線は文字に隠れない。
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        // TextKit 2 のまま描く場合（`viewWillDraw` を経ずに描いた場合）は、描画の途中で切り替えず、
        // 記号の文字をそのまま見せる。
        guard textLayoutManager == nil, containsQuoteBars(),
              let textStorage, let layoutManager, let textContainer else { return }
        // `viewWillDraw` を経ない描画（`cacheDisplay(in:to:)` など）でも、文字を描く前に記号の文字を隠す。
        updateQuoteGlyphs()
        let origin = textContainerOrigin
        let visible = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for bar in PreviewQuoteBars.bars(in: textStorage, layoutManager: layoutManager,
                                         container: textContainer, characterRange: characters) {
            bar.color.setFill()
            bar.rect.offsetBy(dx: origin.x, dy: origin.y).fill(using: .sourceOver)
        }
    }

    func cancelHover() { linkHover.cancel() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard revealSource != nil else { return menu }
        let item = NSMenuItem(title: String(localized: "原文へ移動"),
                              action: #selector(revealSourceFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: nil)
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item, at: 0)
        return menu
    }

    @objc private func revealSourceFromMenu(_ sender: Any?) {
        revealSource?()
    }

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

extension HoverPreviewTextView: @MainActor NSTextStorageDelegate {
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        hasQuoteBars = nil
        // 一時属性は `NSLayoutManager` が編集を受け取った後に付け直す（次の描画の前）。
        quoteGlyphsNeedUpdate = true
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
                                markdownDialect: dialect,
                                preservesSoftLineBreaks: settingsStore.app.preservesSoftLineBreaksInPreview ?? false),
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
                            formatsFrontMatter: settingsStore.app.formatsFrontMatterInPreview ?? false,
                            zoom: settingsStore.zoom(for: .preview),
                            loadsRemoteImages: settingsStore.app.loadsRemoteImages ?? false,
                            theme: settingsStore.previewTheme,
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
        if preferredSnapshot?.matches(source: source, dialect: dialect) == true {
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
        guard generation == requestedGeneration,
              MarkdownTextFormat.identicalText(state.displayedSource, result.source) else { return }
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
            // 「システム」のプレビューの白い背景（GitHub風）と同化しないよう、バーの素材と区切り線で分ける。
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
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

struct FrontMatterPreviewView: View {
    let frontMatter: MarkdownFrontMatter
    let formatsProperties: Bool
    let theme: PreviewTheme
    let zoom: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("フロントマター")
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            if formatsProperties, let rows = FrontMatterPreviewProperties.rows(in: frontMatter) {
                Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow(alignment: .top) {
                            Text(verbatim: row.key)
                                .foregroundStyle(.secondary)
                            Text(verbatim: row.values.joined(separator: " · "))
                                .font(row.isVerbatim ? .system(size: 12 * zoom, design: .monospaced) : .system(size: 12 * zoom))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .gridColumnAlignment(.leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } else {
                Text(verbatim: frontMatter.raw)
                    .font(.system(size: 12 * zoom, design: .monospaced))
            }
        }
        .font(.system(size: 12 * zoom))
        .foregroundStyle(theme.bodyColor.map { Color(nsColor: $0) } ?? .primary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}
