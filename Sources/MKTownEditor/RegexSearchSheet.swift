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
    @State private var matches: [NSRange] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    private struct Query: Hashable, Sendable {
        let source: String
        let pattern: String
        let caseSensitive: Bool
    }

    private struct SearchResult: Sendable {
        let matches: [NSRange]
        let message: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("正規表現で検索・置換")
                .font(.headline)
            Form {
                TextField("検索パターン", text: $pattern)
                TextField("置換文字列（$1 などで参照）", text: $replacement)
                Toggle("大文字小文字を区別", isOn: $caseSensitive)
            }
            .formStyle(.grouped)
            .frame(height: 160)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if isSearching {
                ProgressView("検索中")
            } else {
                Text("一致: \(matches.count) 件")
                    .foregroundStyle(.secondary)
            }

            let lines = MarkdownLineIndex(source)
            List(Array(matches.enumerated()), id: \.offset) { item in
                Button {
                    onSelect(item.element)
                } label: {
                    Text("\(lines.line(containingUTF16Offset: item.element.location)) 行: \(matchText(item.element))")
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
        .task(id: Query(source: source, pattern: pattern, caseSensitive: caseSensitive)) {
            guard !pattern.isEmpty else {
                matches = []
                errorMessage = nil
                isSearching = false
                return
            }
            isSearching = true
            matches = []
            let query = Query(source: source, pattern: pattern, caseSensitive: caseSensitive)
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return SearchResult(matches: try RegexSearch.matches(in: query.source,
                        pattern: query.pattern, caseSensitive: query.caseSensitive), message: nil)
                } catch {
                    return SearchResult(matches: [], message: error.localizedDescription)
                }
            }.value
            guard !Task.isCancelled else { return }
            matches = result.matches
            errorMessage = result.message
            isSearching = false
        }
    }

    private var nextMatch: NSRange? {
        RegexSearch.nextMatch(in: matches, after: selectedRange)
    }

    private var replacementTarget: NSRange? {
        RegexSearch.replacementTarget(in: matches, selection: selectedRange)
    }

    private func matchText(_ range: NSRange) -> String {
        guard range.length > 0 else { return "空位置" }
        return (source as NSString).substring(with: range)
            .replacingOccurrences(of: "\n", with: "↵")
    }

    private func replace(only match: NSRange?) {
        do {
            guard let edit = try RegexSearch.replacementEdit(in: source, pattern: pattern,
                template: replacement, caseSensitive: caseSensitive, onlyMatch: match) else { return }
            if !onReplace(edit, source) {
                errorMessage = "置換できません。本文と編集状態を確認してください。"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
