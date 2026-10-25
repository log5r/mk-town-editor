import SwiftUI

struct MobileEditorWorkspace: View {
    @Binding var document: MarkdownDocument
    @State private var presentation: MobileEditorPresentation = .automatic
    @State private var compactPreview = false
    @State private var selection: TextSelection?
    @State private var preview = MobileMarkdownPreview("")
    @State private var exporting = false
    @State private var exportError: String?
    @State private var previewPosition: Int?
    @FocusState private var editorFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            let layout = MobileEditorLayout(width: geometry.size.width,
                accessibilityText: dynamicTypeSize.isAccessibilitySize,
                presentation: presentation, compactPreview: compactPreview)
            HStack(spacing: 0) {
                if layout.showsEditor {
                    TextEditor(text: $document.text, selection: $selection)
                        .font(.body.monospaced())
                        .focused($editorFocused)
                        .accessibilityLabel("Markdown本文")
                        .accessibilityIdentifier("markdownEditor")
                }
                if layout.showsEditor && layout.showsPreview { Divider() }
                if layout.showsPreview { previewContent }
            }
            .toolbar {
                if !(layout.showsEditor && layout.showsPreview) {
                    ToolbarItem(placement: .primaryAction) {
                        Button(layout.showsEditor ? String(localized: "プレビュー") : String(localized: "編集"),
                               systemImage: layout.showsEditor ? "eye" : "square.and.pencil") {
                            editorFocused = false
                            if presentation == .automatic {
                                compactPreview.toggle()
                            } else {
                                presentation = layout.showsEditor ? .preview : .editor
                            }
                        }
                        .accessibilityIdentifier("togglePreview")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("表示", systemImage: "rectangle.split.2x1") {
                        Picker("表示", selection: $presentation) {
                            Text("自動").tag(MobileEditorPresentation.automatic)
                            Text("編集").tag(MobileEditorPresentation.editor)
                            Text("プレビュー").tag(MobileEditorPresentation.preview)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("コピーを書き出す", systemImage: "square.and.arrow.up") { exporting = true }
                }
            }
        }
        .task(id: document.text) {
            // Coalesce typing; keep parsing away from the main actor for large documents.
            let source = document.text
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let worker = Task.detached(priority: .userInitiated) { MobileMarkdownPreview(source) }
            let value = await worker.value
            guard !Task.isCancelled else { return }
            preview = value
        }
        .fileExporter(isPresented: $exporting, document: document,
                      contentType: MarkdownDocument.markdownType) { result in
            if case .failure(let error) = result { exportError = error.localizedDescription }
        }
        .alert("書き出しできませんでした", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var previewContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(preview.blocks) { block in
                    previewBlock(block)
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .textSelection(.enabled)
        }
        .scrollPosition(id: $previewPosition)
        .accessibilityIdentifier("markdownPreview")
    }

    @ViewBuilder
    private func previewBlock(_ block: MobileMarkdownPreview.Block) -> some View {
        if block.isRule {
            Divider()
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let marker = block.listMarker { Text(marker) }
                Text(block.text)
                    .font(font(for: block))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(block.headingLevel == nil ? [] : .isHeader)
            }
            .accessibilityElement(children: .combine)
            .padding(.leading, CGFloat(min(block.indentation, 4)) * 12)
            .padding(block.isCode || block.isQuote ? 12 : 0)
            .background(block.isCode || block.isQuote ? Color(uiColor: .secondarySystemBackground) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func font(for block: MobileMarkdownPreview.Block) -> Font {
        if block.isCode { return .body.monospaced() }
        switch block.headingLevel {
        case 1: return .largeTitle.bold()
        case 2: return .title.bold()
        case 3: return .title2.bold()
        case .some: return .headline
        case nil: return .body
        }
    }
}
