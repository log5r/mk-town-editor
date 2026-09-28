import SwiftUI
import UniformTypeIdentifiers

struct ImageEditorSheet: View {
    let draft: MarkdownImageDraft
    let documentContext: DocumentContext
    let onSave: @MainActor (String, ImageInput, String, Int?, ImageTransformOptions?) async throws -> Void

    private enum Source: String, CaseIterable {
        case url = "URL"
        case file = "ファイル"
        var title: String { self == .url ? "URL" : String(localized: "ファイル") }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .url
    @State private var alt: String
    @State private var remoteURL = ""
    @State private var title = ""
    @State private var widthText = ""
    @State private var createsDerivedImage = false
    @State private var maxWidthText = ""
    @State private var maxHeightText = ""
    @State private var outputFormat: ImageOutputFormat = .png
    @State private var outputQuality = 0.85
    @State private var fileURL: URL?
    @State private var showsFileImporter = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(draft: MarkdownImageDraft, documentContext: DocumentContext,
         onSave: @escaping @MainActor (String, ImageInput, String, Int?, ImageTransformOptions?) async throws -> Void) {
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
                    Text(value.title).tag(value)
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
                TextField("表示幅（px、任意）", text: $widthText)
                Text("画像だけの段落では代替テキストをキャプションにも使用します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if source == .file {
                    Toggle("派生画像を作成する", isOn: $createsDerivedImage)
                    if createsDerivedImage {
                        TextField("出力の最大幅（px、任意）", text: $maxWidthText)
                        TextField("出力の最大高さ（px、任意）", text: $maxHeightText)
                        Picker("出力形式", selection: $outputFormat) {
                            ForEach(ImageOutputFormat.allCases, id: \.self) { format in
                                Text(format.rawValue).tag(format)
                            }
                        }
                        if outputFormat != .png {
                            Slider(value: $outputQuality, in: 0.1...1) {
                                Text("画質")
                            }
                            Text("画質 \(Int(outputQuality * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: source == .file ? (createsDerivedImage ? 470 : 310) : 260)

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
        let width = widthText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard width.isEmpty || Int(width).map({ (1...9999).contains($0) }) == true else { return false }
        if source == .file && createsDerivedImage {
            for value in [maxWidthText, maxHeightText] {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty || Int(trimmed).map({ (1...10_000).contains($0) }) == true
                else { return false }
            }
        }
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
        let transform = source == .file && createsDerivedImage ? ImageTransformOptions(
            maxWidth: Int(maxWidthText.trimmingCharacters(in: .whitespacesAndNewlines)),
            maxHeight: Int(maxHeightText.trimmingCharacters(in: .whitespacesAndNewlines)),
            format: outputFormat, quality: outputQuality) : nil
        Task {
            do {
                try await onSave(alt, input, title,
                    Int(widthText.trimmingCharacters(in: .whitespacesAndNewlines)), transform)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
