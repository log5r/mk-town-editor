import SwiftUI

struct WorkspaceNamedLayoutSheet: View {
    let root: URL
    let current: WorkspaceNamedLayout
    let onApply: (WorkspaceNamedLayout) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var layouts: [WorkspaceNamedLayout] = []
    @State private var pendingDeletion: WorkspaceNamedLayout?
    private let store = WorkspaceNamedLayoutStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("作業レイアウト").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("開いている書類、表示モード、サイドバー、分割配置を保存します。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("レイアウト名", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("現在の配置を保存") { save() }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("同じ名前で保存すると、そのレイアウトを更新します。")
                .font(.caption).foregroundStyle(.secondary)
            if layouts.isEmpty {
                ContentUnavailableView("保存したレイアウトはありません",
                    systemImage: "rectangle.3.group")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(layouts) { layout in
                    HStack(spacing: 8) {
                        Button {
                            dismiss()
                            onApply(layout)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(layout.name).fontWeight(.medium)
                                Text("\(layout.documentPaths.count)書類・\(layout.mode.label)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        Button("削除", systemImage: "trash", role: .destructive) {
                            pendingDeletion = layout
                        }
                        .labelStyle(.iconOnly)
                        .help("レイアウトを削除")
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .padding(20)
        .onAppear { layouts = store.layouts(for: root) }
        .confirmationDialog(Text("“\(pendingDeletion?.name ?? "")”を削除しますか？"),
                            isPresented: Binding(get: { pendingDeletion != nil },
                                                 set: { if !$0 { pendingDeletion = nil } }),
                            presenting: pendingDeletion) { layout in
            Button("削除", role: .destructive) {
                store.delete(layout.id, for: root)
                layouts = store.layouts(for: root)
            }
        } message: { _ in
            Text("保存したレイアウトを削除します。開いている書類やファイルは変更されません。この操作は取り消せません。")
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var layout = current
        layout.name = trimmed
        store.save(layout, for: root)
        layouts = store.layouts(for: root)
        name = ""
    }
}
