import SwiftUI

struct PreviewSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool
    @Binding var query: String
    @Binding var caseSensitive: Bool
    /// 入力中の検索語はシート内に保持し、呼び出し元の状態は移動時と閉じる時に更新する。
    @State private var text: String
    @State private var matches: [PreviewSearchMatch] = []
    @State private var isSearching = false
    @State private var selectedMatchID: PreviewSearchMatch.ID?

    let source: String
    let selectedLocation: Int?
    let onNavigate: (PreviewSearchMatch) -> Void

    private struct Request: Equatable {
        let source: String
        let query: String
        let caseSensitive: Bool
    }

    init(query: Binding<String>, caseSensitive: Binding<Bool>, source: String,
         selectedLocation: Int?, onNavigate: @escaping (PreviewSearchMatch) -> Void) {
        _query = query
        _caseSensitive = caseSensitive
        _text = State(initialValue: query.wrappedValue)
        self.source = source
        self.selectedLocation = selectedLocation
        self.onNavigate = onNavigate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プレビュー内を検索").font(.headline)
            Text("検索語（改行も指定できます）").font(.caption)
            TextEditor(text: $text)
                .frame(height: 62)
                .border(Color.secondary.opacity(0.4))
                .focused($queryFocused)
            Toggle("大文字と小文字を区別", isOn: $caseSensitive)
            Group {
                if isSearching {
                    Text("検索中…")
                } else {
                    Text("\(matches.count)件")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // The query field accepts newlines, so ↑↓ stay in it; Tab moves to the results (#60).
            List(matches, selection: $selectedMatchID) { match in
                VStack(alignment: .leading, spacing: 2) {
                    Text("行\(match.line)").font(.subheadline.weight(.semibold))
                    Text(match.excerpt).font(.caption).lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .activatesOnClick { navigate(to: match) }
            }
            .activatesSelectionOnReturn(PreviewSearchMatch.ID.self) { id in
                if let match = matches.first(where: { $0.id == id }) { navigate(to: match) }
            }
            .frame(height: 260)
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("前へ") { move(backwards: true) }
                    .disabled(matches.isEmpty || isSearching)
                Button("次へ") { move(backwards: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(matches.isEmpty || isSearching)
            }
        }
        .frame(width: 500)
        .padding(20)
        .onAppear { queryFocused = true }
        .onDisappear { if query != text { query = text } }
        .task(id: Request(source: source, query: text, caseSensitive: caseSensitive)) {
            await search(Request(source: source, query: text, caseSensitive: caseSensitive))
        }
    }

    /// 入力が落ち着いてから背景で全文を検索し、最新の要求の結果だけを表示する。
    private func search(_ request: Request) async {
        guard !request.query.isEmpty else {
            matches = []
            isSearching = false
            return
        }
        isSearching = true
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        let worker = Task.detached(priority: .userInitiated) {
            PreviewSearch.matches(in: request.source, query: request.query,
                                  caseSensitive: request.caseSensitive)
        }
        // 検索語が変わるとこのタスクが取り消されるため、背景の検索にも取り消しを伝える。
        let found = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard !Task.isCancelled else { return }
        matches = found
        isSearching = false
    }

    private func navigate(to match: PreviewSearchMatch) {
        selectedMatchID = match.id
        if query != text { query = text }
        onNavigate(match)
    }

    private func move(backwards: Bool) {
        if let match = PreviewSearch.next(in: matches,
                                          after: Self.navigationOrigin(query: query, text: text,
                                                                       selectedLocation: selectedLocation),
                                          backwards: backwards) {
            navigate(to: match)
        }
    }

    /// 移動の起点。入力中の検索語が呼び出し元の検索語と異なる間、選択中の位置は前の検索語の
    /// 一致なので使わず、新しい検索語の先頭（または末尾）から探す。
    static func navigationOrigin(query: String, text: String, selectedLocation: Int?) -> Int? {
        query == text ? selectedLocation : nil
    }
}
