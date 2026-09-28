import AppKit
import SwiftUI

struct MarkdownPreview: View {
    let markdown: String
    let documentContext: DocumentContext

    var body: some View {
        let analysis = MarkdownAnalysis(markdown)
        if analysis.blocks.contains(where: { $0.kind == .table }) {
            let visibleBlocks = analysis.blocks.filter { $0.kind != .quote }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleBlocks, id: \.id) { block in
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(0..<quoteDepth(of: block, in: analysis), id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.5))
                                    .frame(width: 2)
                            }
                            if let table = block.table {
                                tableView(table, in: analysis)
                            } else if block.kind == .blank {
                                Text(" ").frame(height: 12)
                            } else {
                                Text(AttributedString(MarkdownRenderer.renderLeaf(block, in: analysis)))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
        } else {
            MarkdownTextPreview(markdown: markdown)
        }
    }

    private func quoteDepth(of block: MarkdownBlock, in analysis: MarkdownAnalysis) -> Int {
        var depth = 0
        var parentID = block.parentID
        while let id = parentID, let parent = analysis.blocks.first(where: { $0.id == id }) {
            if parent.kind == .quote { depth += 1 }
            parentID = parent.parentID
        }
        return depth
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
        .accessibilityLabel("Markdown 表")
    }

    private func tableRow(
        _ cells: [String], table: MarkdownTable, widths: [CGFloat], rowNumber: Int,
        in analysis: MarkdownAnalysis
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(cells.indices, id: \.self) { column in
                Text(AttributedString(MarkdownRenderer.renderTableCell(cells[column], in: analysis)))
                    .frame(width: widths[column], alignment: alignment(table.alignments[column]))
                    .padding(8)
                    .frame(minHeight: 34)
                    .background(rowNumber == 0 ? Color.secondary.opacity(0.08) : Color.clear)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    .textSelection(.enabled)
                    .accessibilityLabel(rowNumber == 0
                        ? "見出し \(cells[column])"
                        : "\(table.header[column])、\(rowNumber) 行目、\(cells[column])")
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

private struct MarkdownTextPreview: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
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
        update(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView)
    }

    private func update(_ textView: NSTextView) {
        textView.textStorage?.setAttributedString(MarkdownRenderer.render(markdown))
    }
}
