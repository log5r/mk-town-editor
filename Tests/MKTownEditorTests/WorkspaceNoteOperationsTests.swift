import Foundation
import XCTest
@testable import MKTownEditor

final class WorkspaceNoteOperationsTests: XCTestCase {
    func testSplitPromotesHeadingAndRebasesRelativeResources() throws {
        let root = URL(fileURLWithPath: "/tmp/note-operations")
        let sourceURL = root.appendingPathComponent("a/source.md")
        let destination = root.appendingPathComponent("b/extracted.md")
        let source = "# Outside\nintro\n\n## Section\n![image](asset.png)\n[back](#outside)\n\n### Inner\n[here](#inner)\n\n## Next\nremaining\n"
        let heading = try XCTUnwrap(MarkdownOutline.entries(in: MarkdownAnalysis(source))
            .first { $0.title == "Section" })
        let plan = try XCTUnwrap(WorkspaceNoteOperations.split(source,
            headingLocation: heading.sourceRange.location, sourceURL: sourceURL,
            destinationURL: destination, workspaceDocuments: [sourceURL]))
        XCTAssertEqual(plan.title, "Section")
        XCTAssertTrue(plan.extractedText.hasPrefix("# Section"))
        XCTAssertTrue(plan.extractedText.contains("## Inner"))
        XCTAssertTrue(plan.extractedText.contains("![image](../a/asset.png)"))
        XCTAssertTrue(plan.extractedText.contains("[back](../a/source.md#outside)"))
        XCTAssertTrue(plan.extractedText.contains("[here](#inner)"))
        XCTAssertFalse(plan.extractedText.contains("## Next"))
        XCTAssertTrue(plan.sourceEdit.applying(to: source).contains("## Next"))
        XCTAssertTrue(plan.sourceEdit.applying(to: source).contains("## Section\n\n"))
        XCTAssertTrue(plan.sourceEdit.applying(to: source).contains("](../b/extracted.md)"))
        XCTAssertFalse(plan.sourceEdit.applying(to: source).contains("![image](asset.png)"))
    }

    func testMergeDemotesHeadingsAndRebasesLinksWithoutChangingInputs() throws {
        let root = URL(fileURLWithPath: "/tmp/note-merge")
        let first = WorkspaceMergeInput(url: root.appendingPathComponent("a/first.md"),
            text: "---\ntitle: First\n---\n# Heading\n![pic](pic.png)\n")
        let second = WorkspaceMergeInput(url: root.appendingPathComponent("b/second.md"),
            text: "Title\n=====\n[go](../a/first.md)\n")
        let destination = root.appendingPathComponent("out/merged.md")
        let result = try XCTUnwrap(WorkspaceNoteOperations.merge([first, second],
            destinationURL: destination, workspaceDocuments: [first.url, second.url]))
        XCTAssertTrue(result.contains("# first\n\n```yaml\ntitle: First\n```\n\n## Heading"))
        XCTAssertTrue(result.contains("![pic](../a/pic.png)"))
        XCTAssertTrue(result.contains("# second\n\n## Title"))
        XCTAssertTrue(result.contains("[go](../a/first.md)"))
        XCTAssertEqual(first.text, "---\ntitle: First\n---\n# Heading\n![pic](pic.png)\n")
    }

    func testCodeLinksAreNotRebased() {
        let root = URL(fileURLWithPath: "/tmp/note-merge")
        let source = "`[code](image.png)`\n```\n![ignored](image.png)\n```\n![used](image.png)"
        let result = WorkspaceNoteOperations.rebaseLinks(source,
            from: root.appendingPathComponent("a/source.md"),
            to: root.appendingPathComponent("b/new.md"), workspaceDocuments: [],
            retainsLocalFragments: true)
        XCTAssertTrue(result.contains("`[code](image.png)`"))
        XCTAssertTrue(result.contains("![ignored](image.png)"))
        XCTAssertTrue(result.contains("![used](../a/image.png)"))
    }

    func testSplitRollbackRemovesNewFileWhenSourceEditFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = "# Section\nbody\n"
        let sourceURL = root.appendingPathComponent("source.md")
        let destination = root.appendingPathComponent("new.md")
        let plan = try XCTUnwrap(WorkspaceNoteOperations.split(source,
            headingLocation: 0, sourceURL: sourceURL,
            destinationURL: destination, workspaceDocuments: [sourceURL]))
        XCTAssertThrowsError(try WorkspaceNoteOperations.applySplit(plan,
            destinationURL: destination, root: root, editSource: { false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let created = try WorkspaceNoteOperations.applySplit(plan,
            destinationURL: destination, root: root, editSource: { true })
        XCTAssertEqual(created, destination)
        XCTAssertEqual(try String(contentsOf: created, encoding: .utf8), plan.extractedText)
    }

    func testReferenceImageDefinitionIsRebased() {
        let root = URL(fileURLWithPath: "/tmp/note-merge")
        let source = "![alt][asset]\n\n[asset]: image.png"
        let result = WorkspaceNoteOperations.rebaseLinks(source,
            from: root.appendingPathComponent("a/source.md"),
            to: root.appendingPathComponent("b/new.md"), workspaceDocuments: [],
            retainsLocalFragments: true)
        XCTAssertEqual(result, "![alt][asset]\n\n[asset]: ../a/image.png")
    }

    @MainActor
    func testSplitPlanDependsOnWorkspaceDocumentsAndSheetKeyIncludesThem() throws {
        let root = URL(fileURLWithPath: "/tmp/note-split-documents")
        let sourceURL = root.appendingPathComponent("a/source.md")
        let destination = root.appendingPathComponent("b/extracted.md")
        let note = root.appendingPathComponent("a/Note.md")
        let sameName = root.appendingPathComponent("c/Note.md")
        let source = "# Top\n\n## Section\nsee [[Note]]\n"
        let heading = try XCTUnwrap(MarkdownOutline.entries(in: MarkdownAnalysis(source))
            .first { $0.title == "Section" })
        let unique = try XCTUnwrap(WorkspaceNoteOperations.split(source,
            headingLocation: heading.sourceRange.location, sourceURL: sourceURL,
            destinationURL: destination, workspaceDocuments: [sourceURL, note]))
        let ambiguous = try XCTUnwrap(WorkspaceNoteOperations.split(source,
            headingLocation: heading.sourceRange.location, sourceURL: sourceURL,
            destinationURL: destination, workspaceDocuments: [sourceURL, note, sameName]))
        XCTAssertNotEqual(unique.extractedText, ambiguous.extractedText,
                          "Adding a same-named note changes how the extracted link is written")
        let key = { (documents: [URL]) in
            WorkspaceNoteSplitSheet.PlanKey(source: source, sourceURL: sourceURL,
                headingLocation: heading.sourceRange.location, destinationURL: destination,
                workspaceDocuments: documents)
        }
        XCTAssertNotEqual(key([sourceURL, note]), key([sourceURL, note, sameName]),
                          "The sheet must not reuse a plan built from an older document list")
    }
}
