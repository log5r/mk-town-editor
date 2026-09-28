import Foundation
import AppKit
import XCTest
@testable import MKTownEditor

final class ImageResourceManagerTests: XCTestCase {
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lGQAAAAASUVORK5CYII=")!

    func testImageAlreadyBesideDocumentUsesRelativePathWithoutCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("図 one.png")
        try png.write(to: image)
        let context = DocumentContext(fileURL: root.appendingPathComponent("README.md"))

        let imported = try ImageResourceManager().importImage(at: image, for: context)

        XCTAssertEqual(imported.relativePath, "図 one.png")
        XCTAssertNil(imported.createdFileURL)
        XCTAssertEqual(context.resolveLocalResource(
            MarkdownLinkSyntax.escapeDestination(imported.relativePath)), image)
    }

    func testOutsideImageCopiesIntoAssetsWithCollisionFreeNameAndRollback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("photo.png")
        try png.write(to: image)
        let context = DocumentContext(fileURL: documents.appendingPathComponent("README.md"))
        let manager = ImageResourceManager()

        let first = try manager.importImage(at: image, for: context)
        let second = try manager.importImage(at: image, for: context)

        XCTAssertEqual(first.relativePath, "assets/photo.png")
        XCTAssertEqual(second.relativePath, "assets/photo-2.png")
        XCTAssertEqual(try Data(contentsOf: first.createdFileURL!), png)
        manager.rollback(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.createdFileURL!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.createdFileURL!.path))
    }

    func testUnsavedDocumentAndInvalidImageAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalid = root.appendingPathComponent("fake.png")
        try Data("not an image".utf8).write(to: invalid)
        let manager = ImageResourceManager()

        XCTAssertThrowsError(try manager.importImage(at: invalid, for: DocumentContext(fileURL: nil))) {
            XCTAssertEqual($0 as? ImageResourceError, .unsavedDocument)
        }
        XCTAssertThrowsError(try manager.importImage(at: invalid,
            for: DocumentContext(fileURL: root.appendingPathComponent("README.md")))) {
            XCTAssertEqual($0 as? ImageResourceError, .invalidImage)
        }
    }

    func testAssetsSymlinkOutsideDocumentIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("documents")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: documents.appendingPathComponent("assets"),
                                                   withDestinationURL: outside)
        let image = root.appendingPathComponent("photo.png")
        try png.write(to: image)

        XCTAssertThrowsError(try ImageResourceManager().importImage(at: image,
            for: DocumentContext(fileURL: documents.appendingPathComponent("README.md")))) {
            XCTAssertEqual($0 as? ImageResourceError, .unsafeAssetsDirectory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("photo.png").path))
    }

    func testRelativeReferenceModeKeepsExternalFileWithoutCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("photo.png")
        try png.write(to: image)
        let context = DocumentContext(fileURL: documents.appendingPathComponent("README.md"))

        let imported = try ImageResourceManager().importImage(at: image, for: context,
                                                              mode: .relativeReference)

        XCTAssertEqual(imported.relativePath, "../photo.png")
        XCTAssertNil(imported.createdFileURL)
        XCTAssertEqual(context.resolveLocalResource(imported.relativePath), image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("assets").path))
    }
}

@MainActor
final class ImageInsertionServiceTests: XCTestCase {
    private let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lGQAAAAASUVORK5CYII=")!

    func testRemoteImageInsertionUsesEditorUndo() async throws {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "photo"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        model.presentImageEditor()
        let context = DocumentContext(fileURL: nil)

        try await ImageInsertionService.insert(alt: "写真", input: .remote("https://example.com/a b.png"),
            title: "title", context: context, model: model, currentContext: { context })

        XCTAssertEqual(view.string, "![写真](https://example.com/a%20b.png \"title\")")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "photo")
    }

    func testFileInsertionCopiesImageAndRollsBackOnStaleDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("photo.png")
        try png.write(to: image)
        let context = DocumentContext(fileURL: documents.appendingPathComponent("README.md"))
        let view = NSTextView()
        view.string = ""
        let model = MarkdownEditorModel()
        model.connect(view)
        model.presentImageEditor()

        try await ImageInsertionService.insert(alt: "写真", input: .file(image), title: "",
            context: context, model: model, currentContext: { context })
        XCTAssertEqual(view.string, "![写真](assets/photo.png)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.appendingPathComponent("assets/photo.png").path))

        model.presentImageEditor()
        view.string = "changed"
        do {
            try await ImageInsertionService.insert(alt: "写真", input: .file(image), title: "",
                context: context, model: model, currentContext: { context })
            XCTFail("A stale image draft must be rejected")
        } catch {
            XCTAssertTrue(error is ImageInsertionError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("assets/photo-2.png").path))
        XCTAssertEqual(view.string, "changed")
    }

    func testDroppedImageUsesCapturedUTF16PositionAndUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("photo.png")
        try png.write(to: image)
        let context = DocumentContext(fileURL: documents.appendingPathComponent("README.md"))
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "😀abc"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        let draft = try XCTUnwrap(model.imageDropDraft(at: 2))

        try await ImageInsertionService.insertDrop(fileURL: image, draft: draft,
                                                   mode: .managedCopy, context: context,
                                                   model: model, currentContext: { context })

        XCTAssertEqual(view.string, "😀![photo](assets/photo.png)abc")
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "😀abc")
    }

    func testStaleDropRollsBackCopiedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("photo.png")
        try png.write(to: image)
        let context = DocumentContext(fileURL: documents.appendingPathComponent("README.md"))
        let view = NSTextView()
        view.string = "original"
        let model = MarkdownEditorModel()
        model.connect(view)
        let draft = try XCTUnwrap(model.imageDropDraft(at: 0))
        view.string = "changed"

        do {
            try await ImageInsertionService.insertDrop(fileURL: image, draft: draft,
                                                       mode: .managedCopy, context: context,
                                                       model: model, currentContext: { context })
            XCTFail("A stale drop must be rejected")
        } catch {
            XCTAssertTrue(error is ImageInsertionError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("assets/photo.png").path))
        XCTAssertEqual(view.string, "changed")
    }
}
