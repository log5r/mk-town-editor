import SwiftUI

struct WorkspaceLinkGraphSheet: View {
    let root: URL
    let focusURL: URL?
    let nodes: [WorkspaceNode]
    let isTruncated: Bool
    let loadOpenBuffers: () throws -> [URL: Data]
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var graph: WorkspaceLinkGraph?
    @State private var showsAll = false
    @State private var selectedURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var worker: Task<WorkspaceLinkGraph, Error>?

    private var displayed: WorkspaceGraphViewData? {
        guard let graph else { return nil }
        let focus = focusURL?.resolvingSymlinksInPath().standardizedFileURL
        let hasFocus = focus.map { graph.nodes.contains($0) } ?? false
        return graph.view(around: focus, showsAll: showsAll || !hasFocus)
    }

    var body: some View {
        // 表示する部分グラフは body ごとに一度だけ求める。
        let displayed = displayed
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("文書リンクのグラフ").font(.headline)
                Spacer()
                Picker("表示範囲", selection: $showsAll) {
                    Text("現在の書類の近傍").tag(false)
                    Text("全体").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Button("更新", systemImage: "arrow.clockwise") { load() }
                    .disabled(isLoading)
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if isLoading {
                ProgressView("文書リンクを調査中")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView("グラフを読み込めませんでした",
                    systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let displayed, !displayed.nodes.isEmpty {
                HStack(spacing: 12) {
                    WorkspaceGraphCanvas(data: displayed, focus: focusURL) { url in
                        dismiss()
                        onOpen(url)
                    }
                    .background(Color.secondary.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: 8))
                    List(displayed.nodes, id: \.self, selection: $selectedURL) { url in
                        Label(relativePath(url), systemImage: "doc.text")
                            .lineLimit(2)
                            .activatesOnClick {
                                dismiss()
                                onOpen(url)
                            }
                    }
                    .activatesSelectionOnReturn(URL.self) { url in
                        dismiss()
                        onOpen(url)
                    }
                    .frame(width: 230)
                }
            } else {
                ContentUnavailableView("表示できる書類がありません",
                    systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let graph, let displayed, !isLoading, errorMessage == nil {
                HStack {
                    Text("\(displayed.nodes.count)書類・\(displayed.edges.count)リンク")
                    if displayed.isLimited {
                        Text("表示は\(displayed.limit)書類までです。")
                    }
                    if graph.isTruncated {
                        Text("ファイル一覧が上限に達しました。")
                    }
                    if graph.skippedDocuments > 0 {
                        Text("読み込めなかった書類: \(graph.skippedDocuments)件")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .padding(20)
        .onAppear(perform: load)
        .onDisappear {
            worker?.cancel()
            worker = nil
        }
    }

    private func relativePath(_ url: URL) -> String {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private func load() {
        worker?.cancel()
        do {
            let buffers = try loadOpenBuffers()
            let root = root
            let nodes = nodes
            let truncated = isTruncated
            isLoading = true
            errorMessage = nil
            let task = Task.detached(priority: .userInitiated) {
                try WorkspaceLinkGraph.scan(root: root, nodes: nodes,
                    openBuffers: buffers, isTruncated: truncated)
            }
            worker = task
            Task {
                do {
                    let result = try await task.value
                    guard !task.isCancelled else { return }
                    graph = result
                    let focus = focusURL?.resolvingSymlinksInPath().standardizedFileURL
                    if focus.map({ result.nodes.contains($0) }) != true { showsAll = true }
                    isLoading = false
                    worker = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard !task.isCancelled else { return }
                    errorMessage = error.localizedDescription
                    isLoading = false
                    worker = nil
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            worker = nil
        }
    }
}

private struct WorkspaceGraphCanvas: View {
    let data: WorkspaceGraphViewData
    let focus: URL?
    let onOpen: (URL) -> Void

    var body: some View {
        GeometryReader { geometry in
            let points = positions(in: geometry.size)
            Canvas { context, _ in
                for edge in data.edges {
                    guard let start = points[edge.source], let end = points[edge.target] else { continue }
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: end)
                    context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)
                }
                for url in data.nodes {
                    guard let point = points[url] else { continue }
                    let isFocus = url == focus
                    let radius: CGFloat = isFocus ? 8 : 6
                    let rect = CGRect(x: point.x - radius, y: point.y - radius,
                        width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect),
                        with: .color(isFocus ? .accentColor : .secondary))
                    if isFocus || data.nodes.count <= 12 {
                        let label = context.resolve(Text(url.deletingPathExtension().lastPathComponent)
                            .font(.caption2))
                        context.draw(label, at: CGPoint(x: point.x, y: point.y + 16))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let nearest = points.min(by: {
                    distance($0.value, location) < distance($1.value, location)
                }), distance(nearest.value, location) < 18 else { return }
                onOpen(nearest.key)
            }
        }
        .accessibilityHidden(true)
    }

    private func positions(in size: CGSize) -> [URL: CGPoint] {
        guard !data.nodes.isEmpty else { return [:] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let focusNode = data.nodes.first { $0 == focus }
        let surrounding = data.nodes.filter { $0 != focusNode }
        var result: [URL: CGPoint] = [:]
        if let focusNode { result[focusNode] = center }
        let radius = max(25, min(size.width, size.height) * 0.36)
        let capacities = [12, 24, 36, 48, 60]
        var offset = 0
        for (ring, capacity) in capacities.enumerated() where offset < surrounding.count {
            let count = min(capacity, surrounding.count - offset)
            let ringRadius = radius * CGFloat(0.25 + 0.18 * Double(ring))
            for index in 0..<count {
                let angle = 2 * Double.pi * Double(index) / Double(count)
                let url = surrounding[offset + index]
                result[url] = CGPoint(x: center.x + cos(angle) * ringRadius,
                                      y: center.y + sin(angle) * ringRadius)
            }
            offset += count
        }
        return result
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
