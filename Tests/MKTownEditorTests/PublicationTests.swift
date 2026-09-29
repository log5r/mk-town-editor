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
