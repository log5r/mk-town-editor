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
    @State private var fileName = ""
    @State private var folderPath = ""
    @State private var didSuggestDestination = false
    @State private var errorMessage: String?
    @State private var planCache = DerivedValueCache<PlanKey, WorkspaceSectionSplit?>()

    /// 分割計画の入力すべて。書類一覧の変化でもWikiリンクの解決先が変わるため、キーに含める。
    struct PlanKey: Equatable {
        let source: String
        let sourceURL: URL
        let headingLocation: Int
        let destinationURL: URL
        let workspaceDocuments: [URL]
    }

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
    }

    /// 既定の保存先は表示時に一度だけ求める。init は親の再描画ごとに呼ばれるため、
    /// 解析やパスの解決をそこで行わない。
    private func suggestDestination() {
        guard !didSuggestDestination else { return }
        didSuggestDestination = true
        let title = MarkdownOutline.entries(in: MarkdownAnalysis(source)).first {
            $0.sourceRange.location == headingLocation
        }?.title ?? String(localized: "セクション")
        let safe = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        fileName = String((safe.isEmpty ? "section" : safe).prefix(80)) + ".md"
        let directory = sourceURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        folderPath = WorkspaceWikiLinks.relativePath(from: root, to: directory)
    }

    private var destinationURL: URL {
        let name = URL(fileURLWithPath: fileName).pathExtension.isEmpty
            ? fileName + ".md" : fileName
        return root.appendingPathComponent(folderPath, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(name)
    }

    /// 分割計画は本文と保存先が変わった時だけ作り直す。
    private func plan(destinationURL: URL) -> WorkspaceSectionSplit? {
        guard didSuggestDestination, !fileName.isEmpty else { return nil }
        let key = PlanKey(source: source, sourceURL: sourceURL, headingLocation: headingLocation,
                          destinationURL: destinationURL, workspaceDocuments: workspaceDocuments)
        return planCache.value(for: key) { key in
            WorkspaceNoteOperations.split(key.source, headingLocation: key.headingLocation,
                sourceURL: key.sourceURL, destinationURL: key.destinationURL,
                workspaceDocuments: key.workspaceDocuments)
        }
    }

    var body: some View {
        let destinationURL = destinationURL
        let plan = plan(destinationURL: destinationURL)
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
                Button("分割") { create(plan, destinationURL: destinationURL) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || fileName.isEmpty)
            }
        }
        .frame(width: 560)
        .padding(20)
        .onAppear(perform: suggestDestination)
    }

    private func create(_ plan: WorkspaceSectionSplit?, destinationURL: URL) {
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
