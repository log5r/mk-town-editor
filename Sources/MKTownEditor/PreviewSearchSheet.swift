import SwiftUI

struct PreviewSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var queryFocused: Bool
    @Binding var query: String
    @Binding var caseSensitive: Bool

    let source: String
    let selectedLocation: Int?
    let onNavigate: (PreviewSearchMatch) -> Void

    private var matches: [PreviewSearchMatch] {
        PreviewSearch.matches(in: source, query: query, caseSensitive: caseSensitive)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("プレビュー内を検索").font(.headline)
            Text("検索語（改行も指定できます）").font(.caption)
            TextEditor(text: $query)
                .frame(height: 62)
                .border(Color.secondary.opacity(0.4))
                .focused($queryFocused)
            Toggle("大文字と小文字を区別", isOn: $caseSensitive)
            Text("\(matches.count)件")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(matches) { match in
                Button {
                    onNavigate(match)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("行\(match.line)").font(.subheadline.weight(.semibold))
                        Text(match.excerpt).font(.caption).lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(height: 260)
            HStack {
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("前へ") { move(backwards: true) }
                    .disabled(matches.isEmpty)
                Button("次へ") { move(backwards: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(matches.isEmpty)
            }
        }
        .frame(width: 500)
        .padding(20)
        .onAppear { queryFocused = true }
    }

    private func move(backwards: Bool) {
        if let match = PreviewSearch.next(in: matches, after: selectedLocation,
                                          backwards: backwards) {
            onNavigate(match)
        }
    }
}
