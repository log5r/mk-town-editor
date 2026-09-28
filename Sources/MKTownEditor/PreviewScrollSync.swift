import Foundation

enum PreviewScrollSync {
    static func block(containingOrBefore sourceLocation: Int,
                      in analysis: MarkdownAnalysis) -> MarkdownBlock? {
        let visible = analysis.blocks.filter { $0.kind != .quote }
        return visible.last(where: { $0.sourceRange.location <= sourceLocation }) ?? visible.first
    }

    static func topBlockID(from origins: [Int: CGFloat], threshold: CGFloat = 24) -> Int? {
        let above = origins.filter { $0.value <= threshold }
        if let candidate = above.max(by: { $0.value < $1.value }) { return candidate.key }
        return origins.min(by: { $0.value < $1.value })?.key
    }
}
