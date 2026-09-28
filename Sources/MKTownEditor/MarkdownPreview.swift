import AppKit
import SwiftUI

struct PreviewNavigationTarget: Equatable {
    let blockID: Int
    let sequence: Int
}

struct MarkdownPreview: View {
    @StateObject private var renderCache = PreviewRenderCache()
    let markdown: String
    let documentContext: DocumentContext
    var onToggleTask: ((Int) -> Void)? = nil
    var snapshot: DocumentSnapshot?
    var usesSharedAnalysis = false
    var navigationTarget: PreviewNavigationTarget?
    var onOpenHeading: ((String) -> Void)?
    var onOpenDocument: ((URL) -> Void)?
    var onVisibleBlockChange: ((Int) -> Void)?
    var onRevealSource: ((NSRange) -> Void)?
    var zoom: Double = 1

    var body: some View {
        if usesSharedAnalysis && snapshot == nil {
            ProgressView("プレビューを準備中")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let analysis = snapshot?.analysis ?? MarkdownAnalysis(markdown)
            if PreviewAccessibility.requiresStructuredView(analysis.blocks) ||
                onVisibleBlockChange != nil || onRevealSource != nil {
                let layout = PreviewLayoutIndex(analysis)
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(layout.visibleBlocks, id: \.id) { block in
                                HStack(alignment: .top, spacing: 8) {
                                    ForEach(0..<layout.quoteDepth(for: block.id), id: \.self) { _ in
                                        Rectangle()
                                            .fill(Color.secondary.opacity(0.5))
                                            .frame(width: 2)
                                            .accessibilityHidden(true)
                                    }
                                    if let table = block.table {
                                        tableView(table, in: analysis)
                                    } else if block.kind == .blank {
                                        Text(" ").frame(height: 12)
                                    } else if let task = block.task {
                                        taskView(block, task: task, in: analysis)
                                    } else {
                                        blockText(block, in: analysis)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(block.id)
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
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                    }
                    .coordinateSpace(name: "markdownPreview")
                    .focusable()
                    .onAppear {
                        if let navigationTarget { proxy.scrollTo(navigationTarget.blockID, anchor: .top) }
                    }
                    .onChange(of: navigationTarget) { _, target in
                        if let target { proxy.scrollTo(target.blockID, anchor: .top) }
                    }
                    .onPreferenceChange(PreviewBlockOriginsKey.self) { origins in
                        if let blockID = PreviewScrollSync.topBlockID(from: origins) {
                            onVisibleBlockChange?(blockID)
                        }
                    }
                }
                .environment(\.openURL, OpenURLAction { url in
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
            } else {
                MarkdownTextPreview(markdown: markdown, documentContext: documentContext,
                                    analysis: snapshot?.analysis, onOpenHeading: onOpenHeading,
                                    onOpenDocument: onOpenDocument, zoom: zoom)
            }
        }
    }

    @ViewBuilder
    private func blockText(_ block: MarkdownBlock, in analysis: MarkdownAnalysis) -> some View {
        let rendered = renderCache.render(block, in: analysis, context: documentContext, zoom: zoom)
        if case let .heading(level) = block.kind {
            Text(AttributedString(rendered))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(PreviewAccessibility.headingLabel(level: level, text: rendered.string))
        } else {
            Text(AttributedString(rendered))
                .textSelection(.enabled)
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

            Text(AttributedString(renderCache.render(block, in: analysis, context: documentContext,
                                                    zoom: zoom, showsTaskPrefix: false)))
                .textSelection(.enabled)
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
                Text(AttributedString(renderCache.renderCell(cells[column], in: analysis,
                    context: documentContext, zoom: zoom)))
                    .frame(width: widths[column], alignment: alignment(table.alignments[column]))
                    .padding(8)
                    .frame(minHeight: 34)
                    .background(rowNumber == 0 ? Color.secondary.opacity(0.08) : Color.clear)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    .textSelection(.enabled)
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

enum PreviewAccessibility {
    static func requiresStructuredView(_ blocks: [MarkdownBlock]) -> Bool {
        blocks.contains { block in
            if case .heading = block.kind { return true }
            return block.kind == .table || block.task != nil
        }
    }

    static func headingLabel(level: Int, text: String) -> String {
        "見出しレベル \(level)、\(text)"
    }

    static func taskLabel(_ content: String) -> String {
        content.isEmpty ? "タスクの完了" : "\(content) の完了"
    }

    static func tableCellLabel(header: String, value: String, rowNumber: Int) -> String {
        rowNumber == 0 ? "列見出し \(header)" : "\(header) 列、\(rowNumber) 行目、\(value)"
    }
}

private struct MarkdownTextPreview: NSViewRepresentable {
    let markdown: String
    let documentContext: DocumentContext
    let analysis: MarkdownAnalysis?
    let onOpenHeading: ((String) -> Void)?
    let onOpenDocument: ((URL) -> Void)?
    let zoom: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        context.coordinator.onOpenHeading = onOpenHeading
        context.coordinator.onOpenDocument = onOpenDocument
        context.coordinator.documentContext = documentContext
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
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onOpenHeading = onOpenHeading
        context.coordinator.onOpenDocument = onOpenDocument
        context.coordinator.documentContext = documentContext
        update(textView, coordinator: context.coordinator)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenHeading: ((String) -> Void)?
        var onOpenDocument: ((URL) -> Void)?
        var documentContext = DocumentContext(fileURL: nil)
        var renderedSource: String?
        var renderedContext: DocumentContext?
        var renderedZoom: Double?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
            guard let url else { return false }
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
                coordinator.renderedZoom != zoom else { return }
        let rendered = analysis.map { MarkdownRenderer.render($0, documentContext: documentContext) }
            ?? MarkdownRenderer.render(markdown, documentContext: documentContext)
        textView.textStorage?.setAttributedString(PreviewTypography.scaled(rendered, by: zoom))
        coordinator.renderedSource = markdown
        coordinator.renderedContext = documentContext
        coordinator.renderedZoom = zoom
    }
}
