import SwiftUI

struct FrontMatterPropertiesSheet: View {
    let source: String
    let canEdit: Bool
    let onApply: (MarkdownEdit, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var applyFailed = false

    private var properties: [FrontMatterProperty] {
        FrontMatterProperties.items(in: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("文書プロパティ").font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            List {
                if properties.isEmpty {
                    Text("編集できる単一行のプロパティはありません")
                        .foregroundStyle(.secondary)
                }
                ForEach(properties) { property in
                    HStack {
                        Text(property.key).frame(width: 130, alignment: .leading)
                        TextField("値", text: Binding(
                            get: { values[property.key] ?? property.value },
                            set: { values[property.key] = $0 }
                        ))
                        .disabled(!canEdit)
                        Button("保存") {
                            apply(FrontMatterProperties.upsert(in: source,
                                key: property.key, value: values[property.key] ?? property.value))
                        }
                        .disabled(!canEdit || (values[property.key] ?? property.value) == property.value)
                        Button(role: .destructive) {
                            apply(FrontMatterProperties.remove(in: source, key: property.key))
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(!canEdit)
                        .accessibilityLabel("\(property.key)を削除")
                    }
                }
            }
            HStack {
                TextField("新しいキー", text: $newKey)
                    .frame(width: 150)
                TextField("値", text: $newValue)
                Button("追加") {
                    guard !properties.contains(where: {
                        $0.key.caseInsensitiveCompare(newKey) == .orderedSame
                    }) else { applyFailed = true; return }
                    apply(FrontMatterProperties.upsert(in: source,
                        key: newKey, value: newValue))
                }
                .disabled(!canEdit || newKey.isEmpty || newValue.isEmpty)
            }
            Text("複雑なYAMLの値やコメントは原文で編集してください。既存の未知の行は保持します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 600, minHeight: 380)
        .padding(20)
        .onChange(of: source) { _, _ in
            values.removeAll()
            newKey = ""
            newValue = ""
        }
        .alert("プロパティを変更できませんでした", isPresented: $applyFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("本文が変更されたか、入力したキーや値が利用できません。")
        }
    }

    private func apply(_ edit: MarkdownEdit?) {
        guard let edit, onApply(edit, source) else {
            applyFailed = true
            return
        }
    }
}
