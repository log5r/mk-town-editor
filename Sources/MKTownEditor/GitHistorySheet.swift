import AppKit
import SwiftUI

struct GitHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let fileURL: URL
    @State private var snapshot: GitSnapshot?
    @State private var selectedRevision: GitRevision?
    @State private var historicalContent = ""
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gitの差分と履歴").font(.title2)
                Spacer()
                Button("更新", systemImage: "arrow.clockwise") {
                    Task { await refresh() }
                }
                .disabled(isLoading)
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if isLoading { ProgressView() }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let snapshot {
                Text(snapshot.rootURL.path).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("保存済みファイルのGit状態を表示しています")
                    .font(.caption).foregroundStyle(.secondary)
                TabView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("フォルダの変更")
                            .font(.headline)
                        ScrollView {
                            Text(snapshot.status.isEmpty ? "変更なし" : snapshot.status)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                        Text("\(snapshot.relativePath) の差分")
                            .font(.headline)
                        GitDiffView(diff: snapshot.diff, placeholder: String(localized: "差分なし"))
                    }
                    .padding(12)
                    .tabItem { Text("差分") }
                    HStack(spacing: 12) {
                        List(snapshot.history) { revision in
                            Button {
                                selectedRevision = revision
                                Task { await loadContent(revision, in: snapshot) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(revision.subject).lineLimit(2)
                                    Text(revision.shortHash)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: 250)
                        GitDiffView(diff: selectedRevision == nil ? "" : historicalContent,
                                    placeholder: selectedRevision == nil
                                        ? String(localized: "履歴から版を選択") : String(localized: "空のファイル"),
                                    highlightsChanges: false)
                    }
                    .tabItem { Text("履歴") }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 780, minHeight: 540)
        .task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let url = fileURL
            snapshot = try await Task.detached(priority: .userInitiated) {
                try GitRepository.load(for: url)
            }.value
            error = nil
        } catch {
            snapshot = nil
            self.error = error.localizedDescription
        }
    }

    private func loadContent(_ revision: GitRevision, in snapshot: GitSnapshot) async {
        do {
            let content = try await Task.detached(priority: .userInitiated) {
                try GitRepository.content(of: revision, in: snapshot)
            }.value
            if selectedRevision == revision { historicalContent = content }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 差分の表示内容。行ごとのビューを作らずに色分けできるよう、追加・削除行の範囲を一度の走査で求める。
struct GitDiffPresentation: Equatable, Sendable {
    static let defaultLineLimit = 5_000

    let text: String
    let additions: [NSRange]
    let deletions: [NSRange]
    let totalLines: Int
    let shownLines: Int

    var isTruncated: Bool { shownLines < totalLines }

    init(_ diff: String, lineLimit: Int? = GitDiffPresentation.defaultLineLimit,
         highlightsChanges: Bool = true) {
        let source = diff as NSString
        let length = source.length
        var additions: [NSRange] = []
        var deletions: [NSRange] = []
        var lineStart = 0
        var lines = 0
        var shown = 0
        var shownEnd = 0
        while lineStart < length {
            let newline = source.range(of: "\n", options: .literal,
                                       range: NSRange(location: lineStart, length: length - lineStart)).location
            let end = newline == NSNotFound ? length : newline
            let next = newline == NSNotFound ? length : newline + 1
            lines += 1
            if lineLimit.map({ shown < $0 }) ?? true {
                shown += 1
                shownEnd = next
                let range = NSRange(location: lineStart, length: end - lineStart)
                if highlightsChanges, range.length > 0 {
                    let prefix = source.substring(with: NSRange(location: lineStart, length: min(3, range.length)))
                    if prefix.hasPrefix("+"), prefix != "+++" { additions.append(range) }
                    if prefix.hasPrefix("-"), prefix != "---" { deletions.append(range) }
                }
            }
            lineStart = next
        }
        totalLines = lines
        shownLines = shown
        text = shown < lines ? source.substring(to: shownEnd) : diff
        self.additions = additions
        self.deletions = deletions
    }
}

/// 差分を読み取り専用のテキストビューで表示する。TextKit が表示範囲だけをレイアウトするため、
/// 数万行の差分でもシートの表示が止まらない。既定では先頭の行だけを表示し、必要な時に全体を表示する。
struct GitDiffView: View {
    let diff: String
    let placeholder: String
    /// 追加・削除行を色分けする。過去の版の本文を表示する場合は `false` にする。
    var highlightsChanges = true
    /// 全体表示を選んだ時の差分。別の差分に変わったら、全体表示は引き継がない。
    @State private var expandedDiff: String?
    @State private var cache = DerivedValueCache<DiffKey, GitDiffPresentation>()

    static func lineLimit(diff: String, expandedDiff: String?) -> Int? {
        expandedDiff == diff ? nil : GitDiffPresentation.defaultLineLimit
    }

    private struct DiffKey: Equatable {
        let diff: String
        let showsAll: Bool
    }

    var body: some View {
        let lineLimit = Self.lineLimit(diff: diff, expandedDiff: expandedDiff)
        let presentation = cache.value(for: DiffKey(diff: diff, showsAll: lineLimit == nil)) {
            GitDiffPresentation($0.diff, lineLimit: $0.showsAll ? nil : GitDiffPresentation.defaultLineLimit,
                                highlightsChanges: highlightsChanges)
        }
        VStack(alignment: .leading, spacing: 6) {
            if diff.isEmpty {
                Text(placeholder)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(8)
            } else {
                GitDiffTextView(presentation: presentation)
                if presentation.isTruncated {
                    HStack {
                        Text("先頭の\(presentation.shownLines)行を表示しています（全\(presentation.totalLines)行）")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("差分全体を表示") { expandedDiff = diff }
                    }
                }
            }
        }
        .onChange(of: diff) { _, _ in expandedDiff = nil }
    }
}

private struct GitDiffTextView: NSViewRepresentable {
    let presentation: GitDiffPresentation

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.layoutManager?.allowsNonContiguousLayout = true
        // 行を折り返さず、横スクロールで長い行を表示する。
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(String(localized: "差分"))
        update(textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView, coordinator: context.coordinator)
    }

    private func update(_ textView: NSTextView, coordinator: Coordinator) {
        guard coordinator.presentation != presentation else { return }
        coordinator.presentation = presentation
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let attributed = NSMutableAttributedString(string: presentation.text, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor
        ])
        for range in presentation.additions {
            attributed.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: range)
        }
        for range in presentation.deletions {
            attributed.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
        }
        textView.textStorage?.setAttributedString(attributed)
    }

    final class Coordinator {
        var presentation: GitDiffPresentation?
    }
}
