import SwiftUI

struct WorkspaceEmbeddedDocumentView: View {
    let reference: WorkspaceEmbedReference
    let documentURL: URL
    let documents: [URL]
    let loadOpenBuffers: (() throws -> [URL: Data])?
    let onOpen: ((URL) -> Void)?
    @State private var expansion: WorkspaceEmbedExpansion?
    @State private var refreshID = 0

    private var targetURL: URL? {
        WorkspaceWikiLinks.resolve(reference.target, from: documentURL, documents: documents)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(reference.target, systemImage: "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let targetURL, let onOpen {
                    Button("元の書類を開く", systemImage: "arrow.up.right") {
                        onOpen(targetURL)
                    }
                    .labelStyle(.iconOnly)
                    .help("元の書類を開く")
                }
            }
            if let expansion {
                if !expansion.text.isEmpty {
                    Text(AttributedString(MarkdownRenderer.render(expansion.text,
                        documentContext: DocumentContext(fileURL: targetURL))))
                        .textSelection(.enabled)
                }
                ForEach(expansion.issues.indices, id: \.self) { index in
                    Label(expansion.issues[index], systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView("埋め込みを読み込み中")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .task(id: refreshID) { await refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refreshID &+= 1
        }
    }

    private func refresh() async {
        let buffers = (try? loadOpenBuffers?()) ?? [:]
        let reference = reference
        let documentURL = documentURL
        let documents = documents
        let task = Task.detached(priority: .utility) {
            WorkspaceDocumentEmbed.expand(reference, from: documentURL,
                documents: documents) { url in
                    let data: Data
                    if let open = buffers[url] {
                        data = open
                    } else {
                        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                              size <= WorkspaceDocumentEmbed.maximumBytes,
                              let file = try? Data(contentsOf: url) else { return nil }
                        data = file
                    }
                    guard data.count <= WorkspaceDocumentEmbed.maximumBytes else { return nil }
                    return try? MarkdownDocument.decode(data)
                }
        }
        let result = await task.value
        guard !Task.isCancelled else { return }
        expansion = result
    }
}
