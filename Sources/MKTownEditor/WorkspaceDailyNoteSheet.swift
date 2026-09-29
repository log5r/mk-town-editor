import SwiftUI

struct WorkspaceDailyNoteSheet: View {
    let root: URL
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date()
    @State private var template: WorkspaceDailyNoteTemplate = .journal
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("日付ノート").font(.headline)
            DatePicker("日付", selection: $date, displayedComponents: .date)
                .datePickerStyle(.compact)
            Picker("テンプレート", selection: $template) {
                ForEach(WorkspaceDailyNoteTemplate.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            Text(WorkspaceDailyNote.destination(for: date, root: root).path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("同じ日付の書類がある場合は、その書類を開きます。")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("開く") { open() }.keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 480)
        .padding(20)
    }

    private func open() {
        do {
            let url = try WorkspaceDailyNote.openOrCreate(for: date, root: root,
                template: template)
            dismiss()
            onOpen(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
