import SwiftUI

struct EditorLineSortSheet: View {
    private enum Key: Hashable {
        case wholeLine, column, regularExpression
    }

    private struct PreviewRequest: Equatable, Sendable {
        let key: EditorLineSortOptions.Key
        let keepsFirstLine: Bool
    }

    private struct KeyPreview {
        let request: PreviewRequest
        let result: Result<[String?], Error>
    }

    let draft: EditorLineSortDraft
    let onSort: (MarkdownEdit) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var key: Key = .wholeLine
    @State private var separator = ","
    @State private var column = "1"
    @State private var pattern = ""
    @State private var capture = "0"
    @State private var ignoresCase = false
    @State private var numeric = false
    @State private var localized = false
    @State private var descending = false
    @State private var keepsFirstLine = false
    @State private var keyPreview: KeyPreview?
    @State private var pendingSort: EditorLineSortOptions?
    @State private var editError: String?

    var body: some View {
        let options = sortOptions
        let request = PreviewRequest(key: options.key, keepsFirstLine: options.keepsFirstLine)
        let result = keyPreview.flatMap { $0.request == request ? $0.result : nil }
        VStack(alignment: .leading, spacing: 16) {
            Text("条件を指定して行を並べ替え")
                .font(.headline)
            Form {
                Picker("比較する部分", selection: $key) {
                    Text("行全体").tag(Key.wholeLine)
                    Text("区切り文字で分けた列").tag(Key.column)
                    Text("正規表現の一致部分").tag(Key.regularExpression)
                }
                switch key {
                case .wholeLine:
                    EmptyView()
                case .column:
                    TextField("区切り文字（タブは\\t）", text: $separator)
                        .font(.body.monospaced())
                    TextField("列番号", text: $column)
                case .regularExpression:
                    TextField("正規表現", text: $pattern)
                        .font(.body.monospaced())
                    TextField("キャプチャ番号（0は一致全体）", text: $capture)
                }
                Toggle("大文字と小文字を区別しない", isOn: $ignoresCase)
                Toggle("数値として比較", isOn: $numeric)
                Toggle("言語の規則に従う", isOn: $localized)
                Toggle("降順", isOn: $descending)
                Toggle("先頭行を固定", isOn: $keepsFirstLine)
            }
            .disabled(pendingSort != nil)
            switch result {
            case .success(let keys):
                if !draft.sample.isEmpty { preview(keys) }
            case .failure(let error):
                Text(error.localizedDescription)
                    .foregroundStyle(.red)
            case nil:
                ProgressView("比較する部分を調べています")
                    .controlSize(.small)
            }
            if let editError {
                Text(editError)
                    .foregroundStyle(.red)
            }
            HStack {
                if pendingSort != nil {
                    ProgressView("行を並べ替えています")
                        .controlSize(.small)
                }
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("並べ替え") {
                    editError = nil
                    pendingSort = options
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pendingSort != nil || (try? result?.get()) == nil)
            }
        }
        .frame(width: 500)
        .padding(20)
        .task(id: request) { await updatePreview(for: request) }
        .task(id: pendingSort) {
            if let pendingSort { await sort(pendingSort) }
        }
    }

    private var sortOptions: EditorLineSortOptions {
        let sortKey: EditorLineSortOptions.Key
        switch key {
        case .wholeLine:
            sortKey = .wholeLine
        case .column:
            sortKey = .column(separator: separator == "\\t" ? "\t" : separator, number: Int(column) ?? 0)
        case .regularExpression:
            sortKey = .regularExpression(pattern: pattern, capture: Int(capture) ?? -1)
        }
        return EditorLineSortOptions(key: sortKey, ignoresCase: ignoresCase, numeric: numeric,
                                     localized: localized, descending: descending, keepsFirstLine: keepsFirstLine)
    }

    private func preview(_ keys: [String?]) -> some View {
        GroupBox("比較に使う文字列のプレビュー") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("元の行")
                    Text("比較する部分")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(draft.sample.indices, id: \.self) { index in
                    GridRow {
                        Text(verbatim: draft.sample[index])
                        if keepsFirstLine && index == 0 {
                            Text("固定する行").foregroundStyle(.secondary)
                        } else if let value = keys[index] {
                            if value.isEmpty {
                                Text("空文字列").foregroundStyle(.secondary)
                            } else {
                                Text(verbatim: value)
                            }
                        } else {
                            Text("比較する部分なし").foregroundStyle(.secondary)
                        }
                    }
                    .font(.body.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func updatePreview(for request: PreviewRequest) async {
        let sample = draft.sample
        do {
            if case .regularExpression = request.key { try await Task.sleep(for: .milliseconds(150)) }
            let worker = Task.detached(priority: .userInitiated) {
                let extract = try EditorLineSortOptions(key: request.key).makeKeyExtractor()
                return try sample.enumerated().map { index, line in
                    try Task.checkCancellation()
                    return request.keepsFirstLine && index == 0 ? nil : extract(line)
                }
            }
            let keys = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            keyPreview = KeyPreview(request: request, result: .success(keys))
        } catch {
            guard !Task.isCancelled else { return }
            keyPreview = KeyPreview(request: request, result: .failure(error))
        }
    }

    private func sort(_ options: EditorLineSortOptions) async {
        let source = draft.source
        let selection = draft.selection
        let worker = Task.detached(priority: .userInitiated) {
            try MarkdownFormatter.lineOperationEdit(.sort(options), in: source, selection: selection)
        }
        do {
            let edit = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            if onSort(edit) {
                dismiss()
            } else {
                editError = String(localized: "並べ替えできませんでした。キャンセルして本文と選択範囲を確認してください。")
            }
        } catch {
            guard !Task.isCancelled else { return }
            editError = error.localizedDescription
        }
        pendingSort = nil
    }
}
