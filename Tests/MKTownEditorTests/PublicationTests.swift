import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class PublicationTests: XCTestCase {
    func testWordPressDraftBuildsHTTPSJSONAndBodyFragment() throws {
        let config = PublicationConfiguration(provider: .wordpress,
            endpoint: "https://example.com/blog", account: "writer", title: "日本語の見出し",
            slug: "sample-post", mode: .draft)
        let plan = try PublicationPlan.make(config, markdown: "# Hello\n\n**world**",
                                            documentURL: nil, credential: "app password")
        XCTAssertEqual(plan.destination.absoluteString,
                       "https://example.com/blog/wp-json/wp/v2/posts")
        XCTAssertEqual(plan.request.httpMethod, "POST")
        XCTAssertTrue(plan.request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plan.request.httpBody)) as? [String: String])
        XCTAssertEqual(body["status"], "draft")
        XCTAssertEqual(body["title"], "日本語の見出し")
        XCTAssertTrue(body["content"]?.contains("<h1") == true)
        XCTAssertFalse(body["content"]?.contains("<html") == true)
        XCTAssertEqual(plan.preview, body["content"])
    }

    // Issue #41: local images were sent as data: URIs in the post body (HTTP 413 / KSES).
    func testWordPressUploadsLocalFilesBeforePostingAndReplacesSources() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = Data([137, 80, 78, 71, 1, 2, 3])
        try photo.write(to: folder.appendingPathComponent("写真 1.PNG"))
        try Data([9]).write(to: folder.appendingPathComponent("clip.mp4"))
        try Data([5]).write(to: folder.appendingPathComponent("diagram.svg"))
        let config = PublicationConfiguration(provider: .wordpress,
            endpoint: "https://example.com/blog", account: "writer", title: "Title",
            slug: "post", mode: .draft)
        let markdown = "![Photo](写真%201.PNG) ![Again](写真%201.PNG) ![Vector](diagram.svg)\n\n!video[Clip](clip.mp4)\n\n\"mktown-upload://1/1.png\""
        let plan = try await PublicationPlan.makeAsync(config, markdown: markdown,
            documentURL: folder.appendingPathComponent("note.md"), credential: "app password")
        XCTAssertEqual(plan.uploads.map(\.fileName), ["1.png", "clip.mp4"])
        XCTAssertEqual(plan.uploads.map(\.mimeType), ["image/png", "video/mp4"])
        XCTAssertFalse(plan.preview.contains("data:image"))
        XCTAssertFalse(plan.preview.contains("file:"))
        XCTAssertTrue(plan.preview.contains("src=\"mktown-upload://1/1.png\" alt=\"Photo\""), plan.preview)
        XCTAssertTrue(plan.preview.contains("Vector"), "unsupported types fall back to alt text")

        let recorder = RequestRecorder()
        let link = try await plan.publish { request in
            recorder.append(request)
            if request.url?.lastPathComponent == "media" {
                let name = request.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                let source = name.contains("clip") ? "https://cdn.example.com/clip.mp4?a=1&b=2"
                    : "https://example.com/blog/wp-content/uploads/1.png"
                return try JSONSerialization.data(withJSONObject: ["source_url": source])
            }
            return try JSONSerialization.data(withJSONObject: ["link": "https://example.com/blog/?p=1"])
        }
        XCTAssertEqual(link?.absoluteString, "https://example.com/blog/?p=1")
        let requests = recorder.requests
        XCTAssertEqual(requests.map { $0.url?.absoluteString }, [
            "https://example.com/blog/wp-json/wp/v2/media", "https://example.com/blog/wp-json/wp/v2/media",
            "https://example.com/blog/wp-json/wp/v2/posts"])
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].httpBody, photo)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Disposition"), "attachment; filename=\"1.png\"")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"),
                       plan.request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[2].httpBody)) as? [String: String])
        let content = try XCTUnwrap(body["content"])
        XCTAssertTrue(content.contains("src=\"https://example.com/blog/wp-content/uploads/1.png\" alt=\"Photo\""), content)
        XCTAssertTrue(content.contains("src=\"https://example.com/blog/wp-content/uploads/1.png\" alt=\"Again\""), content)
        XCTAssertTrue(content.contains("href=\"https://cdn.example.com/clip.mp4?a=1&amp;b=2\""), content)
        XCTAssertTrue(content.contains("&quot;mktown-upload://1/1.png&quot;"), "body text must stay untouched")
        XCTAssertEqual(body["title"], "Title")
    }

    func testWordPressUploadFailureNamesFileAndDoesNotPost() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("photo.png"))
        let config = PublicationConfiguration(provider: .wordpress, endpoint: "https://example.com",
            account: "writer", title: "Title", slug: "post", mode: .draft)
        let plan = try PublicationPlan.make(config, markdown: "![Photo](photo.png)",
            documentURL: folder.appendingPathComponent("note.md"), credential: "secret")
        let recorder = RequestRecorder()
        do {
            _ = try await plan.publish { request in
                recorder.append(request)
                throw PublicationError.response(413, "")
            }
            XCTFail("Expected upload failure")
        } catch let PublicationError.upload(name, detail) {
            XCTAssertEqual(name, "photo.png")
            XCTAssertTrue(detail.contains("HTTP 413"), detail)
        }
        XCTAssertEqual(recorder.requests.map { $0.url?.lastPathComponent }, ["media"])
        do {
            _ = try await plan.publish { _ in try JSONSerialization.data(withJSONObject: ["id": 1]) }
            XCTFail("A response without source_url must not publish a broken image")
        } catch PublicationError.upload(let name, _) { XCTAssertEqual(name, "photo.png") }
    }

    func testPublishWithoutLocalFilesSendsPreparedRequestOnly() async throws {
        let config = PublicationConfiguration(provider: .wordpress, endpoint: "https://example.com",
            account: "writer", title: "Title", slug: "post", mode: .draft)
        let plan = try PublicationPlan.make(config, markdown: "![remote](https://example.com/a.png)",
                                            documentURL: nil, credential: "secret")
        XCTAssertTrue(plan.uploads.isEmpty)
        let recorder = RequestRecorder()
        _ = try await plan.publish { request in
            recorder.append(request)
            return Data("{}".utf8)
        }
        XCTAssertEqual(recorder.requests.map(\.httpBody), [plan.request.httpBody])
        XCTAssertTrue(PublicationError.response(413, "<html>").localizedDescription.contains("HTTP 413"))
        XCTAssertFalse(PublicationError.response(413, "<html>").localizedDescription.contains("<html>"))
    }

    func testUploadFileNamesAreASCIIForContentDisposition() {
        XCTAssertEqual(PublicationUploadCollector.fileName(for: URL(fileURLWithPath: "/tmp/写真.JPG"), index: 3),
                       "upload-3.jpg")
        XCTAssertEqual(PublicationUploadCollector.fileName(for: URL(fileURLWithPath: "/tmp/a \"b\".png"), index: 1),
                       "a--b.png")
    }

    func testGitHubJekyllUsesSeparateDraftAndPublishedPaths() throws {
        let date = Date(timeIntervalSince1970: 0)
        var config = PublicationConfiguration(provider: .githubJekyll,
            endpoint: "owner/repo", account: "pages", title: "A title",
            slug: "new-post", mode: .draft)
        let draft = try PublicationPlan.make(config, markdown: "Body", documentURL: nil,
                                             credential: "token", date: date)
        XCTAssertTrue(draft.destination.path.hasSuffix("/_drafts/new-post.md"))
        let draftBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(draft.request.httpBody)) as? [String: String])
        XCTAssertEqual(draftBody["branch"], "pages")
        XCTAssertEqual(String(data: try XCTUnwrap(Data(base64Encoded: draftBody["content"] ?? "")),
                              encoding: .utf8), draft.preview)
        config.mode = .publish
        let published = try PublicationPlan.make(config, markdown: "Body", documentURL: nil,
                                                 credential: "token", date: date)
        XCTAssertTrue(published.destination.path.hasSuffix("/_posts/1970-01-01-new-post.md"))
        XCTAssertEqual(published.request.httpMethod, "PUT")
        XCTAssertEqual(published.request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertTrue(published.preview.contains("layout: post"))
    }

    func testRejectsInvalidTargetsAndSlugs() {
        var config = PublicationConfiguration(provider: .wordpress,
            endpoint: "http://example.com", account: "writer", title: "T",
            slug: "test", mode: .publish)
        XCTAssertThrowsError(try PublicationPlan.make(config, markdown: "Body",
            documentURL: nil, credential: "secret"))
        config.endpoint = "https://example.com"
        config.slug = "../escape"
        XCTAssertThrowsError(try PublicationPlan.make(config, markdown: "Body",
            documentURL: nil, credential: "secret"))
        config.provider = .githubJekyll
        config.endpoint = "owner/../repo"
        config.slug = "test"
        XCTAssertThrowsError(try PublicationPlan.make(config, markdown: "Body",
            documentURL: nil, credential: "secret"))
        config.endpoint = "../repo"
        XCTAssertThrowsError(try PublicationPlan.make(config, markdown: "Body",
            documentURL: nil, credential: "secret"))
    }

    func testCredentialKeySeparatesProvidersAndAccounts() {
        var config = PublicationConfiguration(provider: .wordpress,
            endpoint: "https://example.com", account: "alice", title: "T",
            slug: "test", mode: .draft)
        let first = PublicationCredentialStore.key(for: config)
        config.account = "bob"
        XCTAssertNotEqual(first, PublicationCredentialStore.key(for: config))
        config.provider = .githubJekyll
        XCTAssertNotEqual(first, PublicationCredentialStore.key(for: config))
        config.provider = .wordpress
        config.endpoint = "https://example.com|alice"
        config.account = "bob"
        let one = PublicationCredentialStore.key(for: config)
        config.endpoint = "https://example.com"
        config.account = "alice|bob"
        XCTAssertNotEqual(one, PublicationCredentialStore.key(for: config))
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { values } }
    func append(_ request: URLRequest) { lock.withLock { values.append(request) } }
}
