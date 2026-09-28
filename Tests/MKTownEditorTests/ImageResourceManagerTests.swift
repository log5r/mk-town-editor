import Foundation
import AppKit
import ImageIO
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

    func testOutsideImageReusesIdenticalAssetAndNumbersDifferentContent() throws {
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
        let anotherFolder = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: anotherFolder, withIntermediateDirectories: true)
        let differentImage = anotherFolder.appendingPathComponent("photo.png")
        try (png + Data([1])).write(to: differentImage)
        let third = try manager.importImage(at: differentImage, for: context)

        XCTAssertEqual(first.relativePath, "assets/photo.png")
        XCTAssertEqual(second.relativePath, "assets/photo.png")
        XCTAssertNil(second.createdFileURL)
        manager.rollback(second)
        XCTAssertEqual(third.relativePath, "assets/photo-2.png")
        XCTAssertEqual(try Data(contentsOf: first.createdFileURL!), png)
        manager.rollback(third)
        XCTAssertFalse(FileManager.default.fileExists(atPath: third.createdFileURL!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.createdFileURL!.path))
    }

    func testFailedCopyRemovesStagingFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("photo.png")
        try png.write(to: image)
        let manager = ImageResourceManager(fileManager: FailingImageCopyManager())

        XCTAssertThrowsError(try manager.importImage(at: image,
            for: DocumentContext(fileURL: documents.appendingPathComponent("README.md"))))
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: documents.appendingPathComponent("assets").path)
        XCTAssertTrue(contents.isEmpty)
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

    func testDerivedImageResizesWithoutChangingSourceAndReusesOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("photo.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40,
            pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let sourceData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try sourceData.write(to: original)
        let context = DocumentContext(fileURL: root.appendingPathComponent("note.md"))
        let options = ImageTransformOptions(maxWidth: 10, maxHeight: nil,
            format: .jpeg, quality: 0.7)
        let manager = ImageResourceManager()

        let first = try manager.deriveImage(at: original, for: context, options: options)
        let second = try manager.deriveImage(at: original, for: context, options: options)

        XCTAssertEqual(first.relativePath, "assets/photo-edited.jpg")
        XCTAssertEqual(second.relativePath, first.relativePath)
        XCTAssertNil(second.createdFileURL)
        XCTAssertEqual(try Data(contentsOf: original), sourceData)
        let output = try XCTUnwrap(first.createdFileURL)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(image) as String?, "public.jpeg")
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
        XCTAssertEqual(properties?[kCGImagePropertyPixelWidth] as? Int, 10)
        XCTAssertEqual(properties?[kCGImagePropertyPixelHeight] as? Int, 5)
    }

    func testDerivedImageRejectsInvalidOptionsAndUnsavedDocument() throws {
        let options = ImageTransformOptions(maxWidth: 0, maxHeight: nil,
            format: .png, quality: 1)
        XCTAssertThrowsError(try ImageResourceManager().deriveImage(
            at: URL(fileURLWithPath: "/tmp/missing.png"),
            for: DocumentContext(fileURL: nil), options: options)) {
            XCTAssertEqual($0 as? ImageResourceError, .unsavedDocument)
        }
        XCTAssertFalse(options.isValid)
    }

    func testFileAttachmentCopiesOrReferencesWithoutChangingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("仕様 one.pdf")
        let original = Data("pdf-content".utf8)
        try original.write(to: file)
        let context = DocumentContext(fileURL: docs.appendingPathComponent("note.md"))
        let manager = FileAttachmentManager()

        let referenced = try manager.importFile(at: file, for: context,
            mode: .relativeReference)
        XCTAssertEqual(referenced.relativePath, "../仕様 one.pdf")
        XCTAssertNil(referenced.createdFileURL)

        let copied = try manager.importFile(at: file, for: context, mode: .managedCopy)
        let repeated = try manager.importFile(at: file, for: context, mode: .managedCopy)
        XCTAssertEqual(copied.relativePath, "assets/仕様 one.pdf")
        XCTAssertEqual(repeated.relativePath, copied.relativePath)
        XCTAssertNil(repeated.createdFileURL)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try Data(contentsOf: copied.createdFileURL!), original)
        XCTAssertEqual(MarkdownLinkSyntax.makeLink(label: "仕様", destination: copied.relativePath),
            "[仕様](assets/仕様%20one.pdf)")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let different = other.appendingPathComponent("仕様 one.pdf")
        try Data("changed".utf8).write(to: different)
        let numbered = try manager.importFile(at: different, for: context, mode: .managedCopy)
        XCTAssertEqual(numbered.relativePath, "assets/仕様 one-2.pdf")
    }
}

private final class FailingImageCopyManager: FileManager {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try Data("partial".utf8).write(to: dstURL)
        throw CocoaError(.fileWriteOutOfSpace)
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
