import AppKit
import Combine
import SwiftMath

struct PreviewLayoutIndex: Sendable {
    let visibleBlocks: [MarkdownBlock]
    private let quoteDepths: [Int: Int]

    init(_ analysis: MarkdownAnalysis) {
        let byID = Dictionary(uniqueKeysWithValues: analysis.blocks.map { ($0.id, $0) })
        visibleBlocks = analysis.blocks.filter { block in
            if analysis.crossReferences.markerBlockIDs.contains(block.id) { return false }
            if block.calloutKind != nil { return true }
            if block.kind == .quote { return false }
            var parent = block.parentID
            while let id = parent, let ancestor = byID[id] {
                if ancestor.calloutKind != nil { return false }
                parent = ancestor.parentID
            }
            return true
        }
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

/// 本文と解析結果だけで決まる、構造化プレビューが必要かどうかの判定。
/// 背景のスナップショット生成時に一度だけ求める。
enum PreviewStructure {
    static func needsStructuredLayout(_ analysis: MarkdownAnalysis, source: String) -> Bool {
        PreviewAccessibility.requiresStructuredView(analysis.blocks) ||
            analysis.blocks.contains(where: { $0.kind == .codeBlock }) ||
            source.contains("![[") ||
            analysis.blocks.contains(where: { MarkdownMedia($0, dialect: analysis.dialect) != nil }) ||
            !analysis.crossReferences.targets.isEmpty ||
            (analysis.dialect == .extended && source.contains("$")) ||
            !analysis.footnotes.entries.isEmpty
    }
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

    private struct CellKey: Hashable {
        let markdown: String
        let resourceRevision: Int?
    }

    private struct Entry {
        let value: NSAttributedString
        var lastUse: UInt64
    }

    /// 上限を超えたら、最近使っていない項目から `trimTarget` 件になるまで除く。
    let capacity: Int
    private var trimTarget: Int { max(1, capacity * 3 / 4) }
    private var blocks: [BlockKey: Entry] = [:]
    private var cells: [CellKey: Entry] = [:]
    private var clock: UInt64 = 0
    private var analysisIdentity: MarkdownAnalysis.Identity?
    private var references: [String: ReferenceSignature]?
    private var footnotes: [FootnoteSignature]?
    private var crossReferences: MarkdownCrossReferences?
    private var context: DocumentContext?
    private var zoom: Double?
    private var theme: PreviewTheme?
    private var formulaValidity: [String: Bool] = [:]
    private(set) var renderCount = 0
    private(set) var signatureComputationCount = 0
    /// このプレビューが要求したローカル画像のデコードの要求元。
    let imageRequester = LocalImageRequester()

    init(capacity: Int = 4_000) {
        self.capacity = capacity
    }

    private struct BlockKey: Hashable {
        let block: BlockSignature
        let resourceRevision: Int?
    }

    func render(_ block: MarkdownBlock, in analysis: MarkdownAnalysis,
                context: DocumentContext, zoom: Double,
                showsTaskPrefix: Bool = true, remoteRevision: Int = 0,
                theme: PreviewTheme = .system) -> NSAttributedString {
        prepare(analysis, context: context, zoom: zoom, theme: theme)
        // 画像の読み込み状況は画像を含み得るブロックの表示だけに影響する。
        let key = BlockKey(block: BlockSignature(block, showsTaskPrefix: showsTaskPrefix),
                           resourceRevision: Self.mayContainImage(block.content) ||
                            block.table.map { Self.mayContainImage($0) } == true ? remoteRevision : nil)
        clock += 1
        if var cached = blocks[key] {
            cached.lastUse = clock
            blocks[key] = cached
            return cached.value
        }
        let leaf = MarkdownRenderer.$localImageRequester.withValue(imageRequester) {
            MarkdownRenderer.renderLeaf(block, in: analysis, showTaskPrefix: showsTaskPrefix,
                                        documentContext: context)
        }
        let rendered = PreviewTypography.themed(PreviewTypography.scaled(leaf, by: zoom),
            kind: block.kind, theme: theme)
        blocks[key] = Entry(value: rendered, lastUse: clock)
        renderCount += 1
        trimIfNeeded()
        return rendered
    }

    func renderCell(_ markdown: String,
                    in analysis: MarkdownAnalysis, context: DocumentContext,
                    zoom: Double, remoteRevision: Int = 0,
                    theme: PreviewTheme = .system) -> NSAttributedString {
        prepare(analysis, context: context, zoom: zoom, theme: theme)
        let key = CellKey(markdown: markdown,
                          resourceRevision: Self.mayContainImage(markdown) ? remoteRevision : nil)
        clock += 1
        if var cached = cells[key] {
            cached.lastUse = clock
            cells[key] = cached
            return cached.value
        }
        let cell = MarkdownRenderer.$localImageRequester.withValue(imageRequester) {
            MarkdownRenderer.renderTableCell(markdown, in: analysis, documentContext: context)
        }
        let rendered = PreviewTypography.themed(PreviewTypography.scaled(cell, by: zoom),
            kind: nil, theme: theme)
        cells[key] = Entry(value: rendered, lastUse: clock)
        renderCount += 1
        trimIfNeeded()
        return rendered
    }

    /// 表示用の数式として描画できるかを、同じLaTeXについて一度だけ判定する。
    func canRenderDisplayFormula(_ formula: MarkdownMath.Formula) -> Bool {
        if let cached = formulaValidity[formula.latex] { return cached }
        var error: NSError?
        let valid = MTMathListBuilder.build(fromString: formula.latex, error: &error) != nil && error == nil
        if formulaValidity.count >= capacity { formulaValidity.removeAll(keepingCapacity: true) }
        formulaValidity[formula.latex] = valid
        return valid
    }

    var cachedEntryCount: Int { blocks.count + cells.count }

    private static func mayContainImage(_ markdown: String) -> Bool { markdown.contains("![") }

    private static func mayContainImage(_ table: MarkdownTable) -> Bool {
        table.header.contains(where: mayContainImage) || table.rows.contains { $0.contains(where: mayContainImage) }
    }

    private func prepare(_ analysis: MarkdownAnalysis, context newContext: DocumentContext,
                         zoom newZoom: Double, theme newTheme: PreviewTheme) {
        if analysisIdentity !== analysis.identity {
            // 参照・脚注の署名は解析結果ごとに一度だけ求める。
            analysisIdentity = analysis.identity
            signatureComputationCount += 1
            let signatures = analysis.references.mapValues {
                ReferenceSignature(destination: $0.destination, title: $0.title)
            }
            let noteSignatures = analysis.footnotes.entries.map {
                FootnoteSignature(id: $0.id, number: $0.number, content: $0.content)
            }
            if references != signatures || footnotes != noteSignatures ||
                crossReferences != analysis.crossReferences {
                removeAll()
                references = signatures
                footnotes = noteSignatures
                crossReferences = analysis.crossReferences
            }
        }
        guard context != newContext || zoom != newZoom || theme != newTheme else { return }
        removeAll()
        context = newContext
        zoom = newZoom
        theme = newTheme
    }

    private func removeAll() {
        blocks.removeAll(keepingCapacity: true)
        cells.removeAll(keepingCapacity: true)
    }

    private func trimIfNeeded() {
        guard blocks.count + cells.count > capacity else { return }
        let uses = (blocks.values.map(\.lastUse) + cells.values.map(\.lastUse)).sorted(by: >)
        let threshold = uses[min(trimTarget, uses.count) - 1]
        blocks = blocks.filter { $0.value.lastUse >= threshold }
        cells = cells.filter { $0.value.lastUse >= threshold }
    }
}
