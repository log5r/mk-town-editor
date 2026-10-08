import AppKit
import Foundation
import Security
import UniformTypeIdentifiers

/// Only these adapters can send publication requests. Configuration and credentials stay local.
enum PublicationProvider: String, CaseIterable, Identifiable, Sendable {
    case wordpress
    case githubJekyll
    var id: String { rawValue }
    var title: String { self == .wordpress ? "WordPress" : "GitHub Pages (Jekyll)" }
}

enum PublicationMode: String, CaseIterable, Identifiable, Sendable {
    case draft, publish
    var id: String { rawValue }
    var title: String { self == .draft ? String(localized: "下書きを作成") : String(localized: "公開") }
}

struct PublicationConfiguration: Sendable, Equatable {
    var provider: PublicationProvider
    var endpoint: String // WordPress HTTPS site URL, or GitHub owner/repository
    var account: String // WordPress username, or GitHub branch
    var title: String
    var slug: String
    var mode: PublicationMode
}

enum PublicationError: LocalizedError {
    case invalidConfiguration
    case invalidCredential
    case response(Int, String)
    case invalidResponse
    case redirect
    case upload(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: String(localized: "公開先、タイトル、スラッグを確認してください。")
        case .invalidCredential: String(localized: "認証情報を入力してください。")
        case .response(413, _):
            String(localized: "送信サイズが公開先の上限を超えたため受け付けられませんでした（HTTP 413）。サーバーのアップロード上限を確認してください。")
        case .response(let code, let detail): String(localized: "公開先がHTTP \(code)を返しました: \(detail)")
        case .invalidResponse: String(localized: "公開先の応答を確認できません。")
        case .redirect: String(localized: "公開先が別のURLへ転送しました。公開先設定を確認してください。")
        case let .upload(name, detail):
            String(localized: "\(name)をWordPressのメディアライブラリへアップロードできませんでした: \(detail)")
        }
    }
}

/// A local image or media file that must reach the WordPress media library before the post.
struct PublicationUpload: Sendable, Equatable {
    let fileURL: URL
    let fileName: String
    let mimeType: String
    /// Written into the body's `src`/`href` until the upload returns its `source_url`.
    let placeholder: String
}

struct PublicationPlan: Sendable {
    let destination: URL
    let preview: String
    let request: URLRequest
    /// WordPress only. Local files are uploaded instead of being embedded as `data:` URIs,
    /// which made the post body exceed `post_max_size` (HTTP 413) or get stripped by KSES.
    var uploads: [PublicationUpload] = []

    @MainActor
    static func make(_ config: PublicationConfiguration, markdown: String,
                     documentURL: URL?, credential: String, date: Date = Date()) throws -> Self {
        let collector = PublicationUploadCollector()
        let html = config.provider == .wordpress
            ? MarkdownHTMLExporter.render(markdown, documentURL: documentURL,
                                          images: .resolver { collector.placeholder(for: $0) }) : ""
        return try makePrepared(config, markdown: markdown, html: html, uploads: collector.uploads,
                                credential: credential, date: date)
    }

    @MainActor
    static func makeAsync(_ config: PublicationConfiguration, markdown: String,
                          documentURL: URL?, credential: String, date: Date = Date()) async throws -> Self {
        let collector = PublicationUploadCollector()
        let html = config.provider == .wordpress
            ? try await MarkdownHTMLExporter.renderAsync(markdown, documentURL: documentURL,
                                                         images: .resolver { collector.placeholder(for: $0) }) : ""
        let uploads = collector.uploads
        return try await DocumentWork.perform {
            try makePrepared(config, markdown: markdown, html: html, uploads: uploads,
                             credential: credential, date: date)
        }
    }

    private static func makePrepared(_ config: PublicationConfiguration, markdown: String, html: String,
                                     uploads: [PublicationUpload], credential: String, date: Date) throws -> Self {
        guard !credential.isEmpty else { throw PublicationError.invalidCredential }
        guard !config.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              config.title.count <= 200 else { throw PublicationError.invalidConfiguration }
        guard validSlug(config.slug) else { throw PublicationError.invalidConfiguration }
        switch config.provider {
        case .wordpress:
            var plan = try wordpress(config, html: html, credential: credential)
            plan.uploads = uploads
            return plan
        case .githubJekyll:
            return try github(config, markdown: markdown, credential: credential, date: date)
        }
    }

    private static func validSlug(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0)
        } && value.first != "-" && value.last != "-"
    }

    private static func wordpress(_ config: PublicationConfiguration, html: String,
                                  credential: String) throws -> Self {
        guard let site = URLComponents(string: config.endpoint), site.scheme == "https",
              let host = site.host, !host.isEmpty, site.user == nil, site.password == nil,
              site.query == nil, site.fragment == nil,
              !config.account.isEmpty, !config.account.contains(":"),
              !config.account.contains("\n") else { throw PublicationError.invalidConfiguration }
        let base = try URL(string: config.endpoint).unwrap(or: PublicationError.invalidConfiguration)
        let destination = base.appendingPathComponent("wp-json/wp/v2/posts")
        guard let start = html.range(of: "<body>"),
              let end = html.range(of: "</body>", range: start.upperBound..<html.endIndex) else {
            throw PublicationError.invalidConfiguration
        }
        let content = String(html[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: String] = ["title": config.title, "slug": config.slug,
                                         "status": config.mode.rawValue, "content": content]
        var request = URLRequest(url: destination)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Basic " + Data("\(config.account):\(credential)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return Self(destination: destination, preview: content, request: request)
    }

    private static func github(_ config: PublicationConfiguration, markdown: String,
                               credential: String, date: Date) throws -> Self {
        let parts = config.endpoint.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
            $0.unicodeScalars.allSatisfy(allowed.contains) }),
              !config.account.isEmpty,
              config.account.unicodeScalars.allSatisfy({ allowed.contains($0) || $0 == "/" }),
              !config.account.contains(".."), !config.account.hasPrefix("/"),
              !config.account.hasSuffix("/") else { throw PublicationError.invalidConfiguration }
        let dateText = DateFormatter.publicationDate.string(from: date)
        let path = config.mode == .draft ? "_drafts/\(config.slug).md" :
            "_posts/\(dateText)-\(config.slug).md"
        let destination = URL(string: "https://api.github.com/repos/\(parts[0])/\(parts[1])/contents/\(path)")!
        let titleJSON = try JSONEncoder().encode(config.title)
        let yamlTitle = String(decoding: titleJSON, as: UTF8.self)
        let content = "---\nlayout: post\ntitle: \(yamlTitle)\n---\n\n\(markdown)"
        let payload = GitHubContentsPayload(message: "Add \(config.mode == .draft ? "draft" : "post") \(config.slug)",
                                            content: Data(content.utf8).base64EncodedString(),
                                            branch: config.account)
        var request = URLRequest(url: destination)
        request.httpMethod = "PUT"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        return Self(destination: destination, preview: content, request: request)
    }

    private struct GitHubContentsPayload: Encodable {
        let message: String
        let content: String
        let branch: String
    }

    /// Uploads `uploads` first, then sends the post with their `source_url`s in place of
    /// the placeholders. `perform` is the network layer; tests replace it.
    func publish(perform: @Sendable (URLRequest) async throws -> Data = PublicationTransport.perform) async throws -> URL? {
        var sources: [String: String] = [:]
        for upload in uploads {
            try Task.checkCancellation()
            do {
                let data = try await perform(try await uploadRequest(upload))
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let source = object["source_url"] as? String,
                      let url = URL(string: source), ["https", "http"].contains(url.scheme?.lowercased() ?? "")
                else { throw PublicationError.invalidResponse }
                sources[upload.placeholder] = source
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PublicationError.upload(upload.fileName, error.localizedDescription)
            }
        }
        return PublicationTransport.link(in: try await perform(try postRequest(replacing: sources)))
    }

    func uploadRequest(_ upload: PublicationUpload) async throws -> URLRequest {
        var request = URLRequest(url: destination.deletingLastPathComponent().appendingPathComponent("media"))
        request.httpMethod = "POST"
        request.setValue(upload.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("attachment; filename=\"\(upload.fileName)\"", forHTTPHeaderField: "Content-Disposition")
        request.setValue(self.request.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
        let fileURL = upload.fileURL
        request.httpBody = try await DocumentWork.perform { try Data(contentsOf: fileURL) }
        return request
    }

    /// Placeholders only appear inside attributes, where the exporter escapes every quote in
    /// user text, so `"` + placeholder cannot match body text. A `#`/`?` suffix is kept.
    func postRequest(replacing sources: [String: String]) throws -> URLRequest {
        guard !sources.isEmpty, let body = request.httpBody,
              var payload = try JSONSerialization.jsonObject(with: body) as? [String: String],
              var content = payload["content"] else { return request }
        for (placeholder, source) in sources {
            let escaped = source.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            content = content.replacingOccurrences(of: "\"" + placeholder, with: "\"" + escaped)
        }
        payload["content"] = content
        var request = request
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }
}

/// Assigns one upload per local file while the WordPress body renders off the main actor.
final class PublicationUploadCollector: @unchecked Sendable {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]
    static let uploadableExtensions = imageExtensions
        .union(MarkdownMedia.Kind.audio.extensions).union(MarkdownMedia.Kind.video.extensions)

    private let lock = NSLock()
    private var byURL: [URL: PublicationUpload] = [:]
    private var ordered: [PublicationUpload] = []

    var uploads: [PublicationUpload] { lock.withLock { ordered } }

    /// Returns nil for missing files and types WordPress does not accept by default,
    /// so the exporter falls back to alt text instead of a broken reference.
    func placeholder(for fileURL: URL) -> String? {
        let ext = fileURL.pathExtension.lowercased()
        guard Self.uploadableExtensions.contains(ext),
              (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return lock.withLock {
            if let existing = byURL[fileURL] { return existing.placeholder }
            let index = ordered.count + 1
            let name = Self.fileName(for: fileURL, index: index)
            let upload = PublicationUpload(fileURL: fileURL, fileName: name,
                mimeType: UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream",
                placeholder: "mktown-upload://\(index)/\(name)")
            byURL[fileURL] = upload
            ordered.append(upload)
            return upload.placeholder
        }
    }

    /// WordPress reads only an ASCII `filename=`, so other characters become hyphens.
    static func fileName(for fileURL: URL, index: Int) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var stem = String.UnicodeScalarView()
        for scalar in fileURL.deletingPathExtension().lastPathComponent.unicodeScalars {
            stem.append(allowed.contains(scalar) ? scalar : "-")
        }
        let clean = String(stem).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (clean.isEmpty ? "upload-\(index)" : clean) + "." + fileURL.pathExtension.lowercased()
    }
}

private extension DateFormatter {
    static let publicationDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private extension Optional {
    func unwrap(or error: Error) throws -> Wrapped {
        guard let self else { throw error }
        return self
    }
}

/// Restrict redirects so the Authorization header never reaches a different host.
private final class PublicationNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum PublicationTransport {
    static func send(_ request: URLRequest) async throws -> URL? {
        link(in: try await perform(request))
    }

    static func perform(_ request: URLRequest) async throws -> Data {
        let session = URLSession(configuration: .ephemeral, delegate: PublicationNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PublicationError.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw PublicationError.redirect }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(500), as: UTF8.self)
            throw PublicationError.response(http.statusCode, detail)
        }
        return data
    }

    static func link(in data: Data) -> URL? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let link = object["link"] as? String { return URL(string: link) }
            if let content = object["content"] as? [String: Any],
               let link = content["html_url"] as? String { return URL(string: link) }
        }
        return nil
    }
}

enum PublicationCredentialStore {
    private static let service = "jp.mktowneditor.publication"

    static func key(for config: PublicationConfiguration) -> String {
        let fields = [config.provider.rawValue, config.endpoint, config.account]
        return fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    static func save(_ credential: String, for config: PublicationConfiguration) throws {
        guard !credential.isEmpty else { throw PublicationError.invalidCredential }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key(for: config)]
        let data = Data(credential.utf8)
        let status = SecItemAdd(query.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(update)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load(for config: PublicationConfiguration) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: key(for: config),
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credential = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return credential
    }
}
