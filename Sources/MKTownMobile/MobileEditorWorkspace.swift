import SwiftUI

struct MobileEditorWorkspace: View {
    @Binding var document: MarkdownDocument
    @AppStorage private(set) var showsFrontMatter: Bool
    @AppStorage private(set) var formatsFrontMatter: Bool
    @AppStorage private(set) var preservesSoftLineBreaks: Bool
    @State private var showingSettings = false
    @State private var editorState = MobileEditorState()
    @State private var selection: TextSelection?
    @StateObject private var previewStore = MobilePreviewStore()
    @State private var exporting = false
    @State private var exportError: String?
    @State private var previewPosition: Int?
    @FocusState private var editorFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(document: Binding<MarkdownDocument>, preferences: UserDefaults = .standard) {
        _document = document
        _showsFrontMatter = AppStorage(wrappedValue: false, "mobile.showsFrontMatterInPreview", store: preferences)
        _formatsFrontMatter = AppStorage(wrappedValue: false, "mobile.formatsFrontMatterInPreview", store: preferences)
        _preservesSoftLineBreaks = AppStorage(wrappedValue: false, "mobile.preservesSoftLineBreaksInPreview", store: preferences)
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = MobileEditorLayout(width: geometry.size.width,
                accessibilityText: dynamicTypeSize.isAccessibilitySize,
                presentation: editorState.presentation, compactPreview: editorState.compactPreview)
            HStack(spacing: 0) {
                if layout.showsEditor {
                    TextEditor(text: $document.text, selection: $selection)
                        .font(.body.monospaced())
                        .focused($editorFocused)
                        .accessibilityLabel("Markdown本文")
                        .accessibilityIdentifier("markdownEditor")
                        .modifier(MobileFindNavigator(editorState: $editorState))
                }
                if layout.showsEditor && layout.showsPreview { Divider() }
                if layout.showsPreview { previewContent }
            }
            .onChange(of: layout.showsEditor) { _, visible in
                if !visible {
                    editorFocused = false
                    editorState.dismissFindNavigator()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("検索・置換", systemImage: "magnifyingglass") {
                        editorState.showFindNavigator()
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .accessibilityIdentifier("findAndReplace")
                }
                if !(layout.showsEditor && layout.showsPreview) {
                    ToolbarItem(placement: .primaryAction) {
                        Button(layout.showsEditor ? String(localized: "プレビュー") : String(localized: "編集"),
                               systemImage: layout.showsEditor ? "eye" : "square.and.pencil") {
                            editorFocused = false
                            editorState.togglePreview(showsEditor: layout.showsEditor)
                        }
                        .accessibilityIdentifier("togglePreview")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu("表示", systemImage: "rectangle.split.2x1") {
                        Picker("表示", selection: $editorState.presentation) {
                            Text("自動").tag(MobileEditorPresentation.automatic)
                            Text("編集").tag(MobileEditorPresentation.editor)
                            Text("プレビュー").tag(MobileEditorPresentation.preview)
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("コピーを書き出す", systemImage: "square.and.arrow.up") { exporting = true }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("設定", systemImage: "gearshape") {
                        editorFocused = false
                        showingSettings = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("openSettings")
                }
            }
        }
        .onAppear { previewStore.update(source: document.text) }
        .onChange(of: document.text) { _, source in previewStore.update(source: source) }
        .onDisappear { previewStore.cancel() }
        .sheet(isPresented: $showingSettings) {
            MobilePreferencesView(preservesSoftLineBreaks: $preservesSoftLineBreaks,
                showsFrontMatter: $showsFrontMatter, formatsFrontMatter: $formatsFrontMatter)
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
                if showsFrontMatter, let frontMatter = previewStore.preview.frontMatter {
                    MobileFrontMatterPreviewView(raw: frontMatter.raw,
                        rows: previewStore.preview.frontMatterRows, formatsProperties: formatsFrontMatter)
                }
                ForEach(previewStore.preview.blocks) { block in
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
                Text(block.displayText(preservesSoftLineBreaks: preservesSoftLineBreaks))
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

/// Native find presentation must follow the editor's insertion and navigation transition.
struct MobileFindNavigator: ViewModifier {
    @Binding var editorState: MobileEditorState

    func body(content: Content) -> some View {
        content
            .findNavigator(isPresented: $editorState.showsFindNavigator)
            .task(id: editorState.findRequested) {
                guard editorState.findRequested else { return }
                // A yield alone can still run before UIKit finishes installing the find interaction.
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { return }
                guard !Task.isCancelled else { return }
                editorState.presentRequestedFindNavigator()
            }
    }
}

struct MobilePreferencesView: View {
    @Binding var preservesSoftLineBreaks: Bool
    @Binding var showsFrontMatter: Bool
    @Binding var formatsFrontMatter: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("本文の改行をそのまま表示", isOn: $preservesSoftLineBreaks)
                        .accessibilityIdentifier("preserveLineBreaks")
                } header: {
                    Text("Markdownの解釈")
                } footer: {
                    Text("オンにすると、段落内の改行1つもプレビューで改行します。オフにすると空白として表示します。原文と書き出しには影響しません。")
                }
                Section {
                    Toggle("フロントマターを表示", isOn: $showsFrontMatter)
                        .accessibilityIdentifier("showFrontMatter")
                    Toggle("Obsidianのプロパティを整形して表示", isOn: $formatsFrontMatter)
                        .disabled(!showsFrontMatter)
                        .accessibilityIdentifier("formatFrontMatter")
                } header: {
                    Text("フロントマター")
                } footer: {
                    Text("先頭のYAMLを項目ごとに小さな文字で表示します。オフにするとYAMLをそのまま表示します。")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                        .accessibilityIdentifier("closeSettings")
                }
            }
        }
    }
}

struct MobileFrontMatterPreviewView: View {
    let raw: String
    let rows: [FrontMatterPreviewProperties.Row]?
    let formatsProperties: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("フロントマター")
                .fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            if formatsProperties, let rows {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            Text(verbatim: row.key).foregroundStyle(.secondary)
                                .fixedSize(horizontal: true, vertical: false)
                            propertyValue(row)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: row.key).foregroundStyle(.secondary)
                            propertyValue(row)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } else {
                Text(verbatim: raw).font(.caption.monospaced())
            }
        }
        .font(.caption)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("frontMatterPreview")
    }

    private func propertyValue(_ row: FrontMatterPreviewProperties.Row) -> some View {
        Text(verbatim: row.values.joined(separator: " · "))
            .font(row.isVerbatim ? .caption.monospaced() : .caption)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
