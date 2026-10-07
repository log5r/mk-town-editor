import Foundation

/// 引用以外のブロックを開始位置の順に並べた索引。スクロール同期で二分探索に使う。
struct PreviewScrollIndex: Sendable {
    private let locations: [Int]
    private let blockIndices: [Int]
    private let locationsByBlockID: [Int: Int]

    init(_ analysis: MarkdownAnalysis) {
        var locations: [Int] = []
        var indices: [Int] = []
        var byID: [Int: Int] = [:]
        for (index, block) in analysis.blocks.enumerated() where block.kind != .quote {
            locations.append(block.sourceRange.location)
            indices.append(index)
            byID[block.id] = block.sourceRange.location
        }
        // 子ブロックは親より後ろに出現するが、開始位置は親の範囲内なので並べ替えて保持する。
        let order = locations.indices.sorted { (locations[$0], $0) < (locations[$1], $1) }
        self.locations = order.map { locations[$0] }
        blockIndices = order.map { indices[$0] }
        locationsByBlockID = byID
    }

    /// 位置を含むか、位置より前で最も後ろにあるブロック。該当がなければ先頭のブロック。
    func block(containingOrBefore sourceLocation: Int, in analysis: MarkdownAnalysis) -> MarkdownBlock? {
        guard !locations.isEmpty else { return nil }
        var low = 0
        var high = locations.count
        while low < high {
            let middle = (low + high) / 2
            if locations[middle] <= sourceLocation { low = middle + 1 } else { high = middle }
        }
        // 同じ開始位置が複数あるときは、元の配列で後ろにあるブロック（`last(where:)` と同じ）を選ぶ。
        let position = low == 0 ? 0 : low - 1
        let index = low == 0 ? blockIndices[0] : blockIndices[position]
        guard analysis.blocks.indices.contains(index) else { return nil }
        return analysis.blocks[index]
    }

    func sourceLocation(ofBlockID id: Int) -> Int? { locationsByBlockID[id] }
}

enum PreviewScrollSync {
    static func block(containingOrBefore sourceLocation: Int,
                      in analysis: MarkdownAnalysis,
                      index: PreviewScrollIndex? = nil) -> MarkdownBlock? {
        (index ?? PreviewScrollIndex(analysis)).block(containingOrBefore: sourceLocation, in: analysis)
    }

    static func topBlockID(from origins: [Int: CGFloat], threshold: CGFloat = 24) -> Int? {
        var above: (id: Int, origin: CGFloat)?
        var first: (id: Int, origin: CGFloat)?
        for (id, origin) in origins {
            if origin <= threshold, above.map({ origin > $0.origin }) ?? true { above = (id, origin) }
            if first.map({ origin < $0.origin }) ?? true { first = (id, origin) }
        }
        return above?.id ?? first?.id
    }
}
