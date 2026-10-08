import SwiftUI

struct PublicationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var source: String
    let documentURL: URL?
    @State private var provider: PublicationProvider = .wordpress
    @State private var mode: PublicationMode = .draft
    @State private var endpoint = ""
    @State private var account = ""
    @State private var title = ""
    @State private var slug = ""
    @State private var credential = ""
    @State private var prepared: PublicationPlan?
    @State private var preparedSource = ""
    @State private var error: String?
    @State private var result: URL?
    @State private var succeeded = false
    @State private var sending = false
    @State private var preparing = false
    @State private var prepareTask: Task<Void, Never>?
    @State private var sendTask: Task<Void, Never>?

    private var configuration: PublicationConfiguration {
        PublicationConfiguration(provider: provider, endpoint: endpoint, account: account,
                                 title: title, slug: slug, mode: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("ブログ・静的サイトへ公開").font(.title2)
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Form {
                Picker("公開先", selection: $provider) {
                    ForEach(PublicationProvider.allCases) { value in Text(value.title).tag(value) }
                }
                Picker("操作", selection: $mode) {
                    ForEach(PublicationMode.allCases) { value in Text(value.title).tag(value) }
                }
                TextField(provider == .wordpress ? "WordPressサイトのHTTPS URL" : "GitHubの所有者/リポジトリ",
                          text: $endpoint)
                TextField(provider == .wordpress ? "WordPressユーザー名" : "Pagesの公開元ブランチ",
                          text: $account)
                TextField("タイトル", text: $title)
                TextField("スラッグ（英小文字・数字・ハイフン）", text: $slug)
                SecureField(provider == .wordpress ? "アプリケーションパスワード" : "GitHubトークン",
                            text: $credential)
                HStack {
                    Button("Keychainに保存") { saveCredential() }
                    Button("Keychainから読込") { loadCredential() }
                }
                Text(provider == .wordpress
                    ? "WordPressの投稿APIへ本文をHTMLとして送信します。"
                    : "Jekyllの公開元ルートに下書きは_drafts、公開記事は_postsとして新規作成します。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("相対リンクと添付の公開先での動作を確認してください。既存の投稿やファイルは上書きしません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .frame(height: 310)
            HStack {
                Button("送信内容を確認") { prepare() }
                    .disabled(sending || preparing)
                if preparing { ProgressView(); Button("中止") { prepareTask?.cancel() } }
                if let prepared {
                    Text(prepared.destination.absoluteString)
                        .font(.caption).textSelection(.enabled).lineLimit(2)
                }
            }
            if let prepared {
                Text("送信される本文").font(.headline)
                ScrollView {
                    Text(prepared.preview)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(Color.secondary.opacity(0.05))
                if !prepared.uploads.isEmpty {
                    Text("送信前にローカルの画像・メディア\(prepared.uploads.count)件をWordPressのメディアライブラリへアップロードし、本文の mktown-upload:// をそのURLに置き換えます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button(sending ? "送信中…" : mode == .draft ? "下書きを作成" : "公開を実行") {
                        publish()
                    }
                    .disabled(sending || source != preparedSource || succeeded)
                    .buttonStyle(.borderedProminent)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if succeeded {
                if let result { Link("公開先で確認", destination: result) }
                else { Text("送信が完了しました。公開先で内容を確認してください。") }
            }
        }
        .padding(20)
        .frame(minWidth: 750, minHeight: 690)
        .onChange(of: provider) { _, _ in prepared = nil; credential = "" }
        .onChange(of: mode) { _, _ in prepared = nil }
        .onChange(of: endpoint) { _, _ in prepared = nil; credential = "" }
        .onChange(of: account) { _, _ in prepared = nil; credential = "" }
        .onChange(of: title) { _, _ in prepared = nil }
        .onChange(of: slug) { _, _ in prepared = nil }
        .onChange(of: credential) { _, _ in prepared = nil }
        .onDisappear { sendTask?.cancel(); prepareTask?.cancel() }
    }

    private func prepare() {
        prepareTask?.cancel()
        let config = configuration, text = source, secret = credential
        preparing = true
        prepared = nil
        prepareTask = Task {
            defer { preparing = false; prepareTask = nil }
            do {
                let plan = try await PublicationPlan.makeAsync(config, markdown: text,
                    documentURL: documentURL, credential: secret)
                guard config == configuration, source == text, secret == credential else { return }
                prepared = plan
                preparedSource = text
                error = nil; result = nil; succeeded = false
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }

    private func publish() {
        guard let prepared, source == preparedSource else { return }
        sending = true
        error = nil
        sendTask = Task {
            do {
                result = try await prepared.publish()
                succeeded = true
            } catch { self.error = error.localizedDescription }
            sending = false
            sendTask = nil
        }
    }

    private func saveCredential() {
        do {
            try PublicationCredentialStore.save(credential, for: configuration)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func loadCredential() {
        do {
            credential = try PublicationCredentialStore.load(for: configuration) ?? ""
            error = credential.isEmpty ? String(localized: "保存済みの認証情報がありません。") : nil
        } catch { self.error = error.localizedDescription }
    }
}
