import SwiftUI

struct RegexSearchSheet: View {
    let source: String
    let selectedRange: NSRange
    let onSelect: (NSRange) -> Void
    let onReplace: (MarkdownEdit, String) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var pattern = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var limitsToSelection = false
    @State private var scope: RegexSelectionScope?
    @State private var matches: [NSRange] = []
    /// 各一致の行番号。行の索引は検索と同じ背景処理で作り、body では作らない。
    @State private var lineNumbers: [Int] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    private struct Query: Hashable, Sendable {
        let source: String
        let pattern: String
        let caseSensitive: Bool
        let scope: NSRange?
    }

    private struct SearchResult: Sendable {
        let matches: [NSRange]
        var lineNumbers: [Int] = []
        let message: String?
    }

    init(source: String, selectedRange: NSRange, initialScope: NSRange,
         onSelect: @escaping (NSRange) -> Void,
         onReplace: @escaping (MarkdownEdit, String) -> Bool) {
        self.source = source
        self.selectedRange = selectedRange
        self.onSelect = onSelect
        self.onReplace = onReplace
        _scope = State(initialValue: RegexSelectionScope(initialScope))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("正規表現で検索・置換")
                .font(.headline)
            Form {
                TextField("検索パターン", text: $pattern)
                TextField("置換文字列（$1 などで参照）", text: $replacement)
                Toggle("大文字小文字を区別", isOn: $caseSensitive)
                Toggle("選択範囲内", isOn: $limitsToSelection)
                    .disabled(scope == nil)
            }
            .formStyle(.grouped)
            .frame(height: 195)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if isSearching {
                ProgressView("検索中")
            } else {
                Text("一致: \(matches.count) 件")
                    .foregroundStyle(.secondary)
            }

            List(Array(matches.enumerated()), id: \.offset) { item in
                Button {
                    onSelect(item.element)
                } label: {
                    Text("\(lineNumbers.indices.contains(item.offset) ? lineNumbers[item.offset] : 0) 行: \(matchText(item.element))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 180)

            HStack {
                Button("次を検索") {
                    if let match = nextMatch { onSelect(match) }
                }
                .disabled(matches.isEmpty || isSearching)
                Button("1件置換") { replace(only: replacementTarget) }
                    .disabled(matches.isEmpty || isSearching)
                Button("すべて置換") { replace(only: nil) }
                    .disabled(matches.isEmpty || isSearching)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 620, height: 460)
        .padding(20)
        .task(id: Query(source: source, pattern: pattern, caseSensitive: caseSensitive,
                        scope: activeScope)) {
            guard !pattern.isEmpty else {
                matches = []
                lineNumbers = []
                errorMessage = nil
                isSearching = false
                return
            }
            isSearching = true
            matches = []
            lineNumbers = []
            let query = Query(source: source, pattern: pattern, caseSensitive: caseSensitive,
                              scope: activeScope)
            let worker = Task.detached(priority: .userInitiated) {
                do {
                    let found = try RegexSearch.matches(in: query.source,
                        pattern: query.pattern, caseSensitive: query.caseSensitive,
                        scope: query.scope)
                    let lines = found.isEmpty ? nil : MarkdownLineIndex(query.source)
                    return SearchResult(matches: found,
                                        lineNumbers: found.map { lines?.line(containingUTF16Offset: $0.location) ?? 0 },
                                        message: nil)
                } catch {
                    return SearchResult(matches: [], message: error.localizedDescription)
                }
            }
            // パターンや本文が変わるとこのタスクが取り消されるため、背景の検索にも伝える。
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            matches = result.matches
            lineNumbers = result.lineNumbers
            errorMessage = result.message
            isSearching = false
        }
    }

    private var nextMatch: NSRange? {
        RegexSearch.nextMatch(in: matches, after: selectedRange)
    }

    private var activeScope: NSRange? {
        limitsToSelection ? scope?.range : nil
    }

    private var replacementTarget: NSRange? {
        RegexSearch.replacementTarget(in: matches, selection: selectedRange)
    }

    private func matchText(_ range: NSRange) -> String {
        guard range.length > 0 else { return String(localized: "空位置") }
        return (source as NSString).substring(with: range)
            .replacingOccurrences(of: "\n", with: "↵")
    }

    private func replace(only match: NSRange?) {
        do {
            guard let edit = try RegexSearch.replacementEdit(in: source, pattern: pattern,
                template: replacement, caseSensitive: caseSensitive,
                scope: activeScope, onlyMatch: match) else { return }
            if !onReplace(edit, source) {
                errorMessage = String(localized: "置換できません。本文と編集状態を確認してください。")
            } else if var currentScope = scope {
                if currentScope.apply(edit) {
                    scope = currentScope
                } else {
                    scope = nil
                    limitsToSelection = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
