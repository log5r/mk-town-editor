import SwiftUI

struct GoToHeadingSheet: View {
    let entries: [MarkdownOutlineEntry]
    let onGo: (MarkdownOutlineEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: Int?
    @State private var didSubmit = false
    @FocusState private var searchFocused: Bool

    private var results: [MarkdownOutlineEntry] {
        MarkdownOutline.search(query, in: entries)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("見出しへ移動")
                .font(.headline)
            TextField("見出し名で検索", text: $query)
                .focused($searchFocused)
                .movesListSelection($selectedID, in: results.map(\.id))
                .onSubmit(go)
            List(results, selection: $selectedID) { entry in
                Text(entry.title)
                    .padding(.leading, CGFloat(entry.level - 1) * 12)
                    .tag(entry.id)
                    .accessibilityLabel("見出しレベル \(entry.level)、\(entry.title)")
                    .activatesOnClick {
                        selectedID = entry.id
                        go()
                    }
            }
            .contextMenu(forSelectionType: Int.self) { _ in } primaryAction: { _ in
                if ListKeyboardSelection.isKeyboardActivation { go() }
            }
            .frame(height: 260)
            Text("↑↓キーで選び、Returnで移動します。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("移動") { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosenEntry == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            selectedID = entries.first?.id
            searchFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedID = results.first?.id
        }
    }

    private var chosenEntry: MarkdownOutlineEntry? {
        results.first(where: { $0.id == selectedID }) ?? results.first
    }

    private func go() {
        guard !didSubmit, let entry = chosenEntry else { return }
        didSubmit = true
        onGo(entry)
        dismiss()
    }
}
