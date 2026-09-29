import SwiftUI

struct AISuggestionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var editorModel: MarkdownEditorModel
    @Binding var source: String
    @State private var operation: AISuggestion.Operation = .proofread
    @State private var targetLanguage = "日本語"
    @State private var apiKey = ""
    @State private var selectedText = ""
    @State private var selectedRange = NSRange(location: 0, length: 0)
    @State private var sourceAtCapture = ""
    @State private var proposal: String?
    @State private var error: String?
    @State private var requesting = false
    @State private var requestTask: Task<Void, Never>?
    @State private var requestID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AIによる推敲・翻訳の提案").font(.title2)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("操作", selection: $operation) {
                ForEach(AISuggestion.Operation.allCases) { value in Text(value.title).tag(value) }
            }
            .pickerStyle(.segmented)
            if operation == .translate {
                TextField("翻訳先の言語", text: $targetLanguage)
            }
            Text("送信先: \(AISuggestion.endpoint.absoluteString) · モデル: \(AISuggestion.model)")
                .font(.caption).textSelection(.enabled)
            Text("送信範囲: 選択中の\(selectedText.count)文字のみ。文書全体とファイル名は送信しません。")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("送信する本文") {
                ScrollView {
                    Text(selectedText).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
            }
            HStack {
                SecureField("OpenAI APIキー", text: $apiKey)
                Button("Keychainに保存") { saveKey() }
                Button("Keychainから読込") { loadKey() }
            }
            Button(requesting ? "送信中…" : "選択範囲を送信して提案を取得") { requestSuggestion() }
                .disabled(requesting || selectedText.isEmpty || source != sourceAtCapture)
            Text("送信はこのボタンを押した時だけ行います。提案は確認後に採用でき、通常の編集はオフラインで使えます。")
                .font(.caption).foregroundStyle(.secondary)
            if let proposal {
                Text("提案の差分").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(AISuggestionDiff.rows(original: selectedText,
                            suggested: proposal).enumerated()), id: \.offset) { _, row in
                            Text(prefix(row.kind) + row.text)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(color(row.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                        }
                    }
                    .textSelection(.enabled)
                }
                .background(Color.secondary.opacity(0.05))
                HStack {
                    if source != sourceAtCapture {
                        Text("文書が変わりました。提案を採用するには選択し直してください。")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("提案を採用") { applyProposal() }
                        .disabled(source != sourceAtCapture || proposal == selectedText)
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 670)
        .onAppear { captureSelection() }
        .onDisappear { requestTask?.cancel() }
        .onChange(of: operation) { _, _ in cancelRequest() }
        .onChange(of: targetLanguage) { _, _ in cancelRequest() }
    }

    private func prefix(_ kind: AISuggestionDiff.Kind) -> String {
        switch kind {
        case .unchanged: "  "
        case .removed: "− "
        case .added: "+ "
        }
    }

    private func color(_ kind: AISuggestionDiff.Kind) -> Color {
        switch kind {
        case .unchanged: .primary
        case .removed: .red
        case .added: .green
        }
    }

    private func captureSelection() {
        let range = editorModel.selectedRange
        let snapshot = source
        guard editorModel.hasActiveEditor,
              editorModel.selectedRanges.count == 1,
              let revision = AISuggestionRevision(source: snapshot, range: range) else {
            error = AISuggestion.SuggestionError.emptySelection.localizedDescription
            return
        }
        let text = revision.selectedText
        guard text.count <= 6_000 else {
            error = AISuggestion.SuggestionError.tooLong.localizedDescription
            return
        }
        selectedRange = range
        selectedText = text
        sourceAtCapture = snapshot
        error = nil
    }

    private func requestSuggestion() {
        guard source == sourceAtCapture else { return }
        do {
            let request = try AISuggestion.request(selectedText: selectedText,
                operation: operation, targetLanguage: targetLanguage, apiKey: apiKey)
            proposal = nil
            error = nil
            requesting = true
            let id = UUID()
            requestID = id
            requestTask = Task {
                do {
                    let value = try await AISuggestionTransport.suggest(request)
                    if !Task.isCancelled, requestID == id { proposal = value }
                } catch {
                    if !Task.isCancelled, requestID == id {
                        self.error = error.localizedDescription
                    }
                }
                if requestID == id {
                    requesting = false
                    requestTask = nil
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func cancelRequest() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        requesting = false
        proposal = nil
    }

    private func applyProposal() {
        guard let proposal,
              let revision = AISuggestionRevision(source: sourceAtCapture, range: selectedRange),
              let edit = revision.edit(suggested: proposal, currentSource: source),
              editorModel.applyRegexEdit(edit, expectedSource: sourceAtCapture) else {
            error = String(localized: "編集中の文書が変わりました。選択し直してください。")
            return
        }
        dismiss()
    }

    private func saveKey() {
        do { try AICredentialStore.save(apiKey); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func loadKey() {
        do {
            apiKey = try AICredentialStore.load() ?? ""
            error = apiKey.isEmpty ? String(localized: "保存済みのAPIキーがありません。") : nil
        } catch { self.error = error.localizedDescription }
    }
}
