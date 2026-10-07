import Combine
import Foundation
import SwiftUI

struct MarkdownMinimapPlan: Equatable, Sendable {
    let lineStarts: [Int]
    let bars: [Double]
    let sourceLength: Int

    var lineCount: Int { lineStarts.count }

    static func make(source: String, maximumBars: Int = 600) -> MarkdownMinimapPlan? {
        let text = source as NSString
        var starts = [0]
        var offset = 0
        while offset < text.length {
            if offset % 4096 == 0 && Task.isCancelled { return nil }
            let unit = text.character(at: offset)
            if unit == 13 && offset + 1 < text.length && text.character(at: offset + 1) == 10 {
                offset += 2
                starts.append(offset)
            } else if unit == 10 || unit == 13 {
                offset += 1
                starts.append(offset)
            } else {
                offset += 1
            }
        }
        let count = max(1, min(maximumBars, starts.count))
        var bars: [Double] = []
        bars.reserveCapacity(count)
        for bin in 0..<count {
            if Task.isCancelled { return nil }
            let first = bin * starts.count / count
            let last = min(starts.count, max(first + 1, (bin + 1) * starts.count / count))
            var longest = 0
            for line in first..<last {
                let end = line + 1 < starts.count ? starts[line + 1] : text.length
                let newlineLength: Int
                if end > starts[line], line + 1 < starts.count {
                    newlineLength = end - starts[line] >= 2 &&
                        text.character(at: end - 2) == 13 && text.character(at: end - 1) == 10 ? 2 : 1
                } else {
                    newlineLength = 0
                }
                longest = max(longest, end - starts[line] - newlineLength)
            }
            bars.append(min(1, Double(longest) / 80))
        }
        return MarkdownMinimapPlan(lineStarts: starts, bars: bars, sourceLength: text.length)
    }

    func location(at fraction: Double) -> Int {
        let clamped = min(1, max(0, fraction))
        let line = min(lineStarts.count - 1, Int(clamped * Double(lineStarts.count)))
        return lineStarts[line]
    }
}

@MainActor
final class MarkdownMinimapStore: ObservableObject {
    @Published private(set) var plan: MarkdownMinimapPlan?
    @Published private(set) var isCurrent = false
    private var requestedSource: String?
    private var generation = 0
    private var task: Task<Void, Never>?

    func update(source: String) {
        if requestedSource == source { return }
        generation += 1
        let version = generation
        requestedSource = source
        isCurrent = false
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled,
                  let plan = MarkdownMinimapPlan.make(source: source) else { return }
            await self?.publish(plan, generation: version)
        }
    }

    private func publish(_ result: MarkdownMinimapPlan, generation version: Int) {
        guard version == generation else { return }
        plan = result
        isCurrent = true
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        requestedSource = nil
        isCurrent = false
    }
}

struct MarkdownMinimapView: View {
    @StateObject private var store = MarkdownMinimapStore()
    let source: String
    /// スクロール位置はこのビューだけが監視し、ワークスペース全体を再描画しない。
    @ObservedObject var viewportState: EditorViewportState
    let onNavigate: (Int) -> Void

    private var viewport: EditorViewport { viewportState.viewport }

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let plan = store.plan else { return }
                let rowHeight = size.height / CGFloat(plan.bars.count)
                for (index, width) in plan.bars.enumerated() where width > 0 {
                    let bar = CGRect(x: 5, y: CGFloat(index) * rowHeight,
                                     width: (size.width - 10) * CGFloat(width),
                                     height: max(1, rowHeight * 0.55))
                    context.fill(Path(bar), with: .color(.secondary.opacity(0.42)))
                }
                let top = CGFloat(viewport.topFraction) * size.height
                let height = max(8, CGFloat(viewport.visibleFraction) * size.height)
                let marker = CGRect(x: 1, y: top, width: size.width - 2,
                                    height: min(height, size.height - top))
                context.fill(Path(marker), with: .color(.accentColor.opacity(0.15)))
                context.stroke(Path(marker), with: .color(.accentColor.opacity(0.7)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard store.isCurrent, let plan = store.plan, geometry.size.height > 0 else { return }
                onNavigate(plan.location(at: Double(value.location.y / geometry.size.height)))
            })
            .accessibilityLabel("文書ミニマップ")
            .accessibilityValue("位置 \(Int(viewport.topFraction * 100))%")
            .accessibilityAdjustableAction { direction in
                guard store.isCurrent, let plan = store.plan else { return }
                let change = direction == .increment ? 0.1 : -0.1
                onNavigate(plan.location(at: viewport.topFraction + change))
            }
            .help("クリックまたはドラッグして文書内を移動")
        }
        .frame(width: 76)
        .background(Color.secondary.opacity(0.04))
        .onAppear { store.update(source: source) }
        .onChange(of: source) { _, current in store.update(source: current) }
        .onDisappear { store.cancel() }
    }
}
