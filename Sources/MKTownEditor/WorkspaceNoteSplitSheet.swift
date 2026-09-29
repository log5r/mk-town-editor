import SwiftUI

struct WorkspaceNoteSplitSheet: View {
    let root: URL
    let sourceURL: URL
    let source: String
    let headingLocation: Int
    let workspaceDocuments: [URL]
    let onCreate: (WorkspaceSectionSplit, URL, String) throws -> URL
    let onOpen: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var fileName: String
    @State private var folderPath: String
    @State private var errorMessage: String?

    init(root: URL, sourceURL: URL, source: String, headingLocation: Int,
         workspaceDocuments: [URL],
         onCreate: @escaping (WorkspaceSectionSplit, URL, String) throws -> URL,
         onOpen: @escaping (URL) -> Void) {
        self.root = root
        self.sourceURL = sourceURL
        self.source = source
        self.headingLocation = headingLocation
        self.workspaceDocuments = workspaceDocuments
        self.onCreate = onCreate
        self.onOpen = onOpen
        let title = MarkdownOutline.entries(in: MarkdownAnalysis(source)).first {
            $0.sourceRange.location == headingLocation
        }?.title ?? String(localized: "セクション")
        let safe = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _fileName = State(initialValue: String((safe.isEmpty ? "section" : safe).prefix(80)) + ".md")
        let directory = sourceURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        _folderPath = State(initialValue: WorkspaceWikiLinks.relativePath(from: root, to: directory))
    }

    private var destinationURL: URL {
        let name = URL(fileURLWithPath: fileName).pathExtension.isEmpty
            ? fileName + ".md" : fileName
        return root.appendingPathComponent(folderPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(name)
    }

    private var plan: WorkspaceSectionSplit? {
        WorkspaceNoteOperations.split(source, headingLocation: headingLocation,
            sourceURL: sourceURL, destinationURL: destinationURL,
            workspaceDocuments: workspaceDocuments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("セクションを別書類に分割").font(.headline)
            TextField("ファイル名", text: $fileName)
                .textFieldStyle(.roundedBorder)
            TextField("ワークスペース内の保存先フォルダ", text: $folderPath)
                .textFieldStyle(.roundedBorder)
            Text(destinationURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let plan {
                Text(String(plan.extractedText.prefix(4_000)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 180, alignment: .topLeading)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            Text("元の書類には見出しと移動先を残し、本文を新しい書類へ移します。")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("分割") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || fileName.isEmpty)
            }
        }
        .frame(width: 560)
        .padding(20)
    }

    private func create() {
        guard let plan else { return }
        do {
            let url = try onCreate(plan, destinationURL, source)
            dismiss()
            onOpen(url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
