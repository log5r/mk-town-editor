import SwiftUI

struct CloudFileStatusSheet: View {
    @Environment(\.dismiss) private var dismiss
    let fileURL: URL
    @Binding var source: String
    let useText: (String, String) -> Bool
    @State private var status: CloudFileStatus?
    @State private var versions: [NSFileVersion] = []
    @State private var diskText = ""
    @State private var selectedText = ""
    @State private var selectedTitle = "ディスク版"
    @State private var adoptedText: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("同期状態と競合版").font(.title2)
                Spacer()
                Button("更新", systemImage: "arrow.clockwise") { refresh() }
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(fileURL.path).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let status {
                HStack {
                    Text(status.isUbiquitous ? "iCloud管理のファイル" : "ローカルまたはファイルプロバイダのファイル")
                    if status.needsDownload { Text("未ダウンロード").foregroundStyle(.orange) }
                    else if status.isDownloading { Text("ダウンロード中").foregroundStyle(.secondary) }
                    if status.hasUnresolvedConflicts || !versions.isEmpty {
                        Text("競合あり").foregroundStyle(.orange)
                    }
                }
                if let date = status.modificationDate {
                    Text("ディスク更新: \(date.formatted())")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if status.needsDownload {
                    Button("ダウンロードを開始") {
                        do { try CloudFileVersions.requestDownload(at: fileURL); refresh() }
                        catch { self.error = error.localizedDescription }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if diskText != source {
                Text("ディスクの内容が編集中の文書と異なります")
                    .foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading) {
                    Text("比較する版").font(.headline)
                    Button("ディスク版") {
                        selectedText = diskText
                        selectedTitle = "ディスク版"
                        adoptedText = nil
                    }
                    ForEach(Array(versions.enumerated()), id: \.offset) { index, version in
                        Button("競合版 \(index + 1) · \(version.modificationDate?.formatted() ?? "日時不明")") {
                            do {
                                selectedText = try CloudFileVersions.read(version)
                                selectedTitle = "競合版 \(index + 1)"
                                adoptedText = nil
                                error = nil
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                    Spacer()
                    Button("選択版を編集中の文書に採用") {
                        if useText(selectedText, source) {
                            adoptedText = selectedText
                            error = nil
                        } else {
                            error = String(localized: "編集中の文書が変わりました。更新してから再試行してください。")
                        }
                    }
                    .disabled(status == nil || status?.needsDownload == true)
                    Button("競合の解消を確定") {
                        guard let adoptedText else { return }
                        do {
                            try CloudFileVersions.resolve(at: fileURL, selectedText: adoptedText)
                            self.adoptedText = nil
                            refresh()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(versions.isEmpty || adoptedText == nil)
                    Text("採用後に文書を保存し、保存完了後に解消を確定してください。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 270, alignment: .leading)
                comparison(title: "編集中の文書", content: source)
                comparison(title: selectedTitle, content: selectedText)
            }
        }
        .padding(20)
        .frame(minWidth: 1000, minHeight: 620)
        .task { refresh() }
    }

    private func comparison(title: String, content: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(content).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.secondary.opacity(0.05))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refresh() {
        do {
            status = try CloudFileStatus.read(at: fileURL)
            versions = CloudFileVersions.unresolved(at: fileURL)
            diskText = status?.needsDownload == true ? "" : try CloudFileVersions.readCurrent(at: fileURL)
            selectedText = diskText
            selectedTitle = "ディスク版"
            adoptedText = nil
            error = nil
        } catch {
            status = nil
            versions = []
            diskText = ""
            selectedText = ""
            adoptedText = nil
            self.error = error.localizedDescription
        }
    }
}
