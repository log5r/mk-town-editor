import SwiftUI
import UniformTypeIdentifiers

struct ImageEditorSheet: View {
    let draft: MarkdownImageDraft
    let documentContext: DocumentContext
    let onSave: @MainActor (String, ImageInput, String) async throws -> Void

    private enum Source: String, CaseIterable {
        case url = "URL"
        case file = "ファイル"
    }

    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .url
    @State private var alt: String
    @State private var remoteURL = ""
    @State private var title = ""
    @State private var fileURL: URL?
    @State private var showsFileImporter = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(draft: MarkdownImageDraft, documentContext: DocumentContext,
         onSave: @escaping @MainActor (String, ImageInput, String) async throws -> Void) {
        self.draft = draft
        self.documentContext = documentContext
        self.onSave = onSave
        _alt = State(initialValue: draft.alt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("画像を挿入")
                .font(.headline)
            Picker("画像の取得元", selection: $source) {
                ForEach(Source.allCases, id: \.self) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(.segmented)

            Form {
                if source == .url {
                    TextField("画像の URL", text: $remoteURL)
                } else {
                    HStack {
                        Text(fileURL?.lastPathComponent ?? "ファイル未選択")
                            .foregroundStyle(fileURL == nil ? .secondary : .primary)
                        Spacer()
                        Button("ファイルを選択…") { showsFileImporter = true }
                            .disabled(documentContext.directoryURL == nil)
                    }
                    if documentContext.directoryURL == nil {
                        Text("ファイル画像を挿入するには、先に文書を保存してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                TextField("代替テキスト", text: $alt)
                TextField("タイトル（任意）", text: $title)
            }
            .formStyle(.grouped)
            .frame(height: source == .file && documentContext.directoryURL == nil ? 210 : 180)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("キャンセル") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("挿入") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .frame(width: 500)
        .padding(20)
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.image],
                      allowsMultipleSelection: false) { result in
            switch result {
            case let .success(urls):
                fileURL = urls.first
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private var canSave: Bool {
        guard !isSaving, !alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch source {
        case .url:
            let candidate = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "%20")
            guard let components = URLComponents(string: candidate),
                  let scheme = components.scheme?.lowercased() else { return false }
            return (scheme == "http" || scheme == "https") && components.host != nil
        case .file:
            return fileURL != nil && documentContext.directoryURL != nil
        }
    }

    private func save() {
        let input: ImageInput
        switch source {
        case .url: input = .remote(remoteURL.trimmingCharacters(in: .whitespacesAndNewlines))
        case .file:
            guard let fileURL else { return }
            input = .file(fileURL)
        }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(alt, input, title)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
