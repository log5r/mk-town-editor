import AppKit
import ImageIO
import XCTest
@testable import MKTownEditor

@MainActor
final class ImagePasteTests: XCTestCase {
    private var png: Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB,
                                      bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.setColor(.red, atX: 0, y: 0)
        return bitmap.representation(using: .png, properties: [:])!
    }

    func testImageClipboardDataIsDetectedWithoutInterceptingText() {
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("plain text", forType: .string)
        XCTAssertNil(EditorTextView.imageData(in: board))

        board.clearContents()
        board.setData(png, forType: .png)
        XCTAssertEqual(EditorTextView.imageData(in: board), png)
    }

    func testStandardPasteRoutesImageWithoutChangingSourceImmediately() {
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(png, forType: .png)
        let view = EditorTextView()
        view.string = "before"
        view.imagePasteboard = board
        var received: Data?
        view.onImagePaste = { received = $0 }

        view.paste(nil)

        XCTAssertEqual(received, png)
        XCTAssertEqual(view.string, "before")
    }

    func testPastedImageIsPNGWithCollisionFreeName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = DocumentContext(fileURL: root.appendingPathComponent("README.md"))
        let manager = ImageResourceManager()
        let date = Date(timeIntervalSince1970: 0)

        let first = try manager.savePastedImage(png, for: context, now: date)
        let second = try manager.savePastedImage(png, for: context, now: date)

        XCTAssertEqual(first.relativePath, "assets/screenshot-19700101-000000.png")
        XCTAssertEqual(second.relativePath, "assets/screenshot-19700101-000000-2.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(first.createdFileURL! as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertNotNil(CGImageSourceGetType(source))
    }

    func testPastedImageNeedsSavedDocumentAndValidPixels() throws {
        let manager = ImageResourceManager()
        XCTAssertThrowsError(try manager.savePastedImage(png, for: DocumentContext(fileURL: nil))) {
            XCTAssertEqual($0 as? ImageResourceError, .unsavedDocument)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try manager.savePastedImage(Data("invalid".utf8),
            for: DocumentContext(fileURL: root.appendingPathComponent("README.md")))) {
            XCTAssertEqual($0 as? ImageResourceError, .invalidImage)
        }
    }

    func testPasteReplacesSelectionAndIsUndoable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = DocumentContext(fileURL: root.appendingPathComponent("README.md"))
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.allowsUndo = true
        view.string = "hello"
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.makeFirstResponder(view)
        let model = MarkdownEditorModel()
        model.connect(view)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        let draft = try XCTUnwrap(model.imagePasteDraft())

        try await ImageInsertionService.insertPaste(imageData: png, draft: draft,
                                                    context: context, model: model,
                                                    currentContext: { context })

        XCTAssertTrue(view.string.hasPrefix("![スクリーンショット](assets/screenshot-"))
        XCTAssertTrue(view.string.hasSuffix(".png)"))
        view.undoManager?.undo()
        XCTAssertEqual(view.string, "hello")
    }

    func testStalePasteRollsBackCreatedAsset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let context = DocumentContext(fileURL: root.appendingPathComponent("README.md"))
        let view = NSTextView()
        view.string = "before"
        let model = MarkdownEditorModel()
        model.connect(view)
        let draft = try XCTUnwrap(model.imagePasteDraft())
        view.string = "changed"

        do {
            try await ImageInsertionService.insertPaste(imageData: png, draft: draft,
                                                        context: context, model: model,
                                                        currentContext: { context })
            XCTFail("A stale paste must be rejected")
        } catch {
            XCTAssertTrue(error is ImageInsertionError)
        }
        let assets = root.appendingPathComponent("assets")
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: assets.path)).isEmpty)
        XCTAssertEqual(view.string, "changed")
    }
}
