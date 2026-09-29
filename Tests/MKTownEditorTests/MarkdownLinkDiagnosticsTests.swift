import Foundation
import XCTest
@testable import MKTownEditor

final class MarkdownLinkDiagnosticsTests: XCTestCase {
    func testExternalTargetsExcludeCodeAndLocalPaths() {
        let source = """
        [one](https://example.com/a) ![two](http://example.org/b)
        [local](file.md) [fragment](#here)
        `[code](https://code.invalid)`
        ```md
        [fence](https://fence.invalid)
        ```
        [ref]: https://reference.example/path
        """
        let targets = MarkdownExternalLinkChecker.targets(in: source, analysis: MarkdownAnalysis(source))
        XCTAssertEqual(targets.map { $0.url.host }, ["example.com", "example.org", "reference.example"])
        let text = source as NSString
        XCTAssertEqual(text.substring(with: targets[0].sourceRange), "[one](https://example.com/a)")
    }

    func testExternalStatusSeparatesMissingRestrictedAndTemporary() {
        XCTAssertEqual(MarkdownExternalLinkChecker.status(for: 200), .reachable)
        XCTAssertEqual(MarkdownExternalLinkChecker.status(for: 302), .reachable)
        XCTAssertEqual(MarkdownExternalLinkChecker.status(for: 401), .restricted)
        XCTAssertEqual(MarkdownExternalLinkChecker.status(for: 403), .restricted)
        XCTAssertEqual(MarkdownExternalLinkChecker.status(for: 404), .missing)
        XCTAssertEqual(MarkdownExternalLinkChecker.status(for: 410), .missing)
        XCTAssertEqual(MarkdownExternalLinkChecker.status(for: 429), .temporaryFailure)
        XCTAssertEqual(MarkdownExternalLinkChecker.status(for: 503), .temporaryFailure)
        XCTAssertEqual(MarkdownExternalLinkChecker.status(for: 405), .unverified)
    }

    func testExternalInspectionCachesRepeatedURLAndKeepsSourceLocations() async {
        actor HitCounter {
            var count = 0
            func hit() { count += 1 }
        }
        let counter = HitCounter()
        let source = "[a](https://example.com) [b](https://example.com)"
        let targets = MarkdownExternalLinkChecker.targets(in: source, analysis: MarkdownAnalysis(source))
        let checks = await MarkdownExternalLinkChecker.inspect(targets) { _ in
            await counter.hit()
            return 404
        }
        let hitCount = await counter.count
        XCTAssertEqual(hitCount, 1)
        XCTAssertEqual(checks.map(\.status), [.missing, .missing])
        XCTAssertNotEqual(checks[0].target.sourceRange.location, checks[1].target.sourceRange.location)
    }

    func testExternalNetworkErrorIsNotReportedAsMissing() async {
        let source = "[a](https://example.com)"
        let targets = MarkdownExternalLinkChecker.targets(in: source, analysis: MarkdownAnalysis(source))
        let checks = await MarkdownExternalLinkChecker.inspect(targets) { _ in
            throw URLError(.timedOut)
        }
        XCTAssertEqual(checks.map(\.status), [.temporaryFailure])
        XCTAssertNil(checks[0].httpStatus)
    }

    func testReportsMissingLocalResourcesHeadingsAndReferenceDefinitions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Known".utf8).write(to: root.appendingPathComponent("target.md"))
        let source = """
        # Present
        [ok](#present) [heading](#absent)
        ![image](missing.png)
        [file](missing.md) [target](target.md#absent)
        [reference][lost] [valid][id]
        `[code](ghost.md)`
        ```md
        [fence](ghost.md)
        ```
        [id]: https://example.com
        """
        let context = DocumentContext(fileURL: root.appendingPathComponent("source.md"))
        let diagnostics = MarkdownLinkDiagnostics.inspect(source, analysis: MarkdownAnalysis(source),
                                                          context: context)
        XCTAssertEqual(diagnostics.map(\.kind), [.missingHeading, .missingImage, .missingFile,
                                                 .missingHeading, .missingReference])
        XCTAssertEqual(diagnostics.map(\.detail), ["#absent", "missing.png", "missing.md",
                                                   "target.md#absent", "lost"])
        let text = source as NSString
        XCTAssertEqual(text.substring(with: diagnostics[0].sourceRange), "[heading](#absent)")
    }

    func testCurrentDocumentUsesUnsavedSourceForHeadingCheck() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.md")
        try Data("# Old".utf8).write(to: file)
        let source = "# New\n[local](source.md#new)"
        XCTAssertTrue(MarkdownLinkDiagnostics.inspect(source, analysis: MarkdownAnalysis(source),
                                                      context: DocumentContext(fileURL: file)).isEmpty)
    }

    func testInlineLinkScannerRetainsImageFlagAndEscapedParentheses() {
        let links = MarkdownLinkSyntax.inlineLinks(in: "![a](image.png) [b](folder/a\\(1\\).md)")
        XCTAssertEqual(links.map(\.destination), ["image.png", "folder/a(1).md"])
        XCTAssertEqual(links.map(\.isImage), [true, false])
    }

    func testLintFindsHeadingJumpMissingLinkAndMixedListMarkers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "# Main\n### Deep\n- one\n* two\n[bad](missing.md)\n```\n* code\n```"
        let diagnostics = MarkdownLint.inspect(source, analysis: MarkdownAnalysis(source),
            context: DocumentContext(fileURL: root.appendingPathComponent("source.md")))
        XCTAssertEqual(diagnostics.map(\.rule), [.headingHierarchy, .listMarker, .missingLink])
        let text = source as NSString
        XCTAssertEqual(text.substring(with: diagnostics[0].sourceRange), "### Deep\n")
        XCTAssertEqual(text.substring(with: diagnostics[1].sourceRange), "* two\n")
    }

    func testLintDisabledRulesSuppressOnlyTheirDiagnostics() throws {
        let source = "## First\n- one\n+ two"
        let context = DocumentContext(fileURL: nil)
        let all = MarkdownLint.inspect(source, analysis: MarkdownAnalysis(source), context: context)
        XCTAssertEqual(all.map(\.rule), [.headingHierarchy, .listMarker])
        let filtered = MarkdownLint.inspect(source, analysis: MarkdownAnalysis(source),
            context: context, disabled: [.headingHierarchy])
        XCTAssertEqual(filtered.map(\.rule), [.listMarker])
    }
}
