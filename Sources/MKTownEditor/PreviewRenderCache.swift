import AppKit
import Combine

struct PreviewLayoutIndex {
    let visibleBlocks: [MarkdownBlock]
    private let quoteDepths: [Int: Int]

    init(_ analysis: MarkdownAnalysis) {
        let byID = Dictionary(uniqueKeysWithValues: analysis.blocks.map { ($0.id, $0) })
        visibleBlocks = analysis.blocks.filter { $0.kind != .quote }
        var depths: [Int: Int] = [:]
        for block in analysis.blocks {
            var depth = 0
            var parent = block.parentID
            while let id = parent, let ancestor = byID[id] {
                if ancestor.kind == .quote { depth += 1 }
                parent = ancestor.parentID
            }
            depths[block.id] = depth
        }
        quoteDepths = depths
    }

    func quoteDepth(for blockID: Int) -> Int { quoteDepths[blockID] ?? 0 }
}

@MainActor
final class PreviewRenderCache: ObservableObject {
    private struct BlockSignature: Hashable {
        struct TableSignature: Hashable {
            let header: [String]
            let rows: [[String]]
            let alignments: [MarkdownTable.Alignment]
        }

        let kind: MarkdownBlock.Kind
        let content: String
        let codeLanguage: String?
        let lineBreaks: [MarkdownLineBreak]
        let nestingDepth: Int
        let hasParent: Bool
        let showsTaskPrefix: Bool
        let table: TableSignature?

        init(_ block: MarkdownBlock, showsTaskPrefix: Bool) {
            kind = block.kind
            content = block.content
            codeLanguage = block.codeLanguage
            lineBreaks = block.lineBreaks
            nestingDepth = block.nestingDepth
            hasParent = block.parentID != nil
            self.showsTaskPrefix = showsTaskPrefix
            table = block.table.map {
                TableSignature(header: $0.header, rows: $0.rows, alignments: $0.alignments)
            }
        }
    }

    private struct ReferenceSignature: Equatable {
        let destination: String
        let title: String?
    }

    private struct FootnoteSignature: Equatable {
        let id: String
        let number: Int
        let content: String
    }

    private var blocks: [BlockSignature: NSAttributedString] = [:]
    private var cells: [String: NSAttributedString] = [:]
    private var references: [String: ReferenceSignature]?
    private var footnotes: [FootnoteSignature]?
    private var context: DocumentContext?
    private var zoom: Double?
    private(set) var renderCount = 0

    func render(_ block: MarkdownBlock, in analysis: MarkdownAnalysis,
                context: DocumentContext, zoom: Double,
                showsTaskPrefix: Bool = true) -> NSAttributedString {
        prepare(references: analysis.references, footnotes: analysis.footnotes,
                context: context, zoom: zoom)
        let signature = BlockSignature(block, showsTaskPrefix: showsTaskPrefix)
        if let cached = blocks[signature] { return cached }
        let rendered = PreviewTypography.scaled(
            MarkdownRenderer.renderLeaf(block, in: analysis, showTaskPrefix: showsTaskPrefix,
                                        documentContext: context), by: zoom)
        blocks[signature] = rendered
        renderCount += 1
        trimIfNeeded()
        return rendered
    }

    func renderCell(_ markdown: String,
                    in analysis: MarkdownAnalysis, context: DocumentContext,
                    zoom: Double) -> NSAttributedString {
        prepare(references: analysis.references, footnotes: analysis.footnotes,
                context: context, zoom: zoom)
        if let cached = cells[markdown] { return cached }
        let rendered = PreviewTypography.scaled(
            MarkdownRenderer.renderTableCell(markdown, in: analysis, documentContext: context),
            by: zoom)
        cells[markdown] = rendered
        renderCount += 1
        trimIfNeeded()
        return rendered
    }

    private func prepare(references newReferences: [String: MarkdownReference],
                         footnotes newFootnotes: MarkdownFootnoteIndex,
                         context newContext: DocumentContext, zoom newZoom: Double) {
        let signatures = newReferences.mapValues {
            ReferenceSignature(destination: $0.destination, title: $0.title)
        }
        let noteSignatures = newFootnotes.entries.map {
            FootnoteSignature(id: $0.id, number: $0.number, content: $0.content)
        }
        guard references != signatures || footnotes != noteSignatures ||
              context != newContext || zoom != newZoom else { return }
        blocks.removeAll()
        cells.removeAll()
        references = signatures
        footnotes = noteSignatures
        context = newContext
        zoom = newZoom
    }

    private func trimIfNeeded() {
        if blocks.count + cells.count > 4_000 {
            blocks.removeAll(keepingCapacity: true)
            cells.removeAll(keepingCapacity: true)
        }
    }
}
