import AppKit
import XCTest
@testable import MKTownEditor

/// Sheets have a Return default, file panels attach to their window, and failures share one
/// alert or appear inline (#29).
@MainActor
final class SheetPresentationTests: XCTestCase {
    private var sourcesURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/MKTownEditor")
    }

    private func source(_ name: String) throws -> String {
        try String(contentsOf: sourcesURL.appendingPathComponent(name), encoding: .utf8)
    }

    func testPresentedErrorsHaveDistinctTitlesAndKeepTheirMessage() {
        let errors: [WorkspacePresentedError] = [
            .missingHeading("x"), .documentLink("x"), .htmlExport("x"), .pdfExport("x"),
            .print("x"), .richCopy("x"), .plainExport("x"), .workspaceOpen("x"),
            .imageInsert("x"), .encodingImport("x")
        ]
        XCTAssertEqual(Set(errors.map(\.title)).count, errors.count)
        XCTAssertEqual(Set(errors.map(\.id)).count, errors.count)
        XCTAssertEqual(WorkspacePresentedError.pdfExport("disk full").message, "disk full")
        XCTAssertTrue(WorkspacePresentedError.missingHeading("intro").message.contains("#intro"))
    }

    func testWorkspaceDeclaresASingleErrorAlert() throws {
        let workspace = try source("EditorWorkspace.swift")
        XCTAssertEqual(workspace.components(separatedBy: "presenting: presentedError").count - 1, 1)
        XCTAssertFalse(workspace.contains("@State private var htmlExportError"))
    }

    func testFilePanelsAreNotAppModalOutsideTheServicesHandler() throws {
        for url in try FileManager.default.contentsOfDirectory(at: sourcesURL, includingPropertiesForKeys: nil)
        where url.pathExtension == "swift" && url.lastPathComponent != "AutomationDocumentWriter.swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("panel.runModal()"), url.lastPathComponent)
        }
    }

    func testRegexSearchAndFileOperationSheetsHaveDefaultButtons() throws {
        let regex = try source("RegexSearchSheet.swift")
        let find = try XCTUnwrap(regex.range(of: "Button(\"次を検索\")"))
        XCTAssertTrue(regex[find.upperBound...].prefix(160).contains(".keyboardShortcut(.defaultAction)"))
        let operations = try source("WorkspaceFileOperationSheet.swift")
        XCTAssertFalse(operations.contains("Button(\"変更を確認\")"))
    }

    func testMoveWithoutLinksAppliesWithoutReviewButLinkedMoveIsReviewed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("note.md")
        try "body".write(to: source, atomically: true, encoding: .utf8)
        let lone = try WorkspaceFileOperations.planMove(source: source,
            destination: root.appendingPathComponent("renamed.md"), root: root)
        XCTAssertTrue(WorkspaceFileOperationSheet.appliesWithoutReview(lone))

        try "[note](note.md)".write(to: root.appendingPathComponent("index.md"),
                                    atomically: true, encoding: .utf8)
        let linked = try WorkspaceFileOperations.planMove(source: source,
            destination: root.appendingPathComponent("renamed.md"), root: root)
        XCTAssertGreaterThan(linked.changedLinks, 0)
        XCTAssertFalse(WorkspaceFileOperationSheet.appliesWithoutReview(linked))
    }

    func testFailedClipboardTableConversionShowsInlineNotice() {
        let view = EditorTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        pasteboard.setString("not a table", forType: .string)
        let model = MarkdownEditorModel()
        model.tablePasteboard = pasteboard
        model.connect(view)
        model.convertClipboardTable()
        XCTAssertNotNil(model.notice)
        XCTAssertNil(window.attachedSheet)
        XCTAssertEqual(view.string, "")
    }
}
