import Foundation
import Darwin
import XCTest
@testable import MKTownEditor

@MainActor
final class PortablePackageExporterTests: XCTestCase {
    func testCancellationDuringArchiveCreationTerminatesChildAndRemovesTemporaryOutput() async throws {
        // Also cover a child that ignores SIGTERM so cancellation stays bounded.
        for ignoresTermination in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("slow-archive")
            let started = root.appendingPathComponent("started")
            let trap = ignoresTermination ? "trap '' TERM\n" : ""
            let script = "#!/bin/sh\n" + trap + "printf '%s' $$ > \"\(started.path)\"\nprintf 'partial archive' > \"$4\"\nexec /bin/sleep 30\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let plan = PortablePackagePlan(markdown: "body", html: "<p>body</p>", assets: [])
            let task = Task {
                try await DocumentWork.commit {
                    try PortablePackageExporter.export(plan, to: root, name: "book", format: .markdown,
                        zip: true, archiveExecutable: executable)
                }
            }
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: started.path) {
                try await Task.sleep(for: .milliseconds(5))
            }
            let pid = try XCTUnwrap(Int32(try String(contentsOf: started, encoding: .utf8)))
            XCTAssertEqual(Darwin.kill(pid, 0), 0, "Archive child must be running before cancellation")
            let cancellationStarted = ContinuousClock.now
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected archive cancellation") }
            catch { XCTAssertEqual(error as? PortablePackageError, .cancelled) }
            XCTAssertLessThan(cancellationStarted.duration(to: .now), .seconds(2))
            XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "Cancellation must reap the archive child")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("book.zip").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains { $0.hasPrefix(".mktown-") }, "Staging, partial ZIP and stderr must all be removed")
        }
    }

    func testArchiveFailureReportsStderrAndLeavesNoPackage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("failed-archive")
        try "#!/bin/sh\nprintf 'archive fixture failed' >&2\nexit 23\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plan = PortablePackagePlan(markdown: "body", html: "<p>body</p>", assets: [])
        XCTAssertThrowsError(try PortablePackageExporter.export(plan, to: root, name: "book", format: .markdown,
            zip: true, archiveExecutable: executable)) { error in
                XCTAssertEqual(error as? PortablePackageError, .archiveFailed("archive fixture failed"))
            }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".mktown-") || $0 == "book.zip" })
    }

    func testPlanRewritesInlineAndReferenceImagesButKeepsCodeLiteral() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let docs = root.appendingPathComponent("docs")
        let shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data([1]).write(to: shared.appendingPathComponent("one.png"))
        try Data([2]).write(to: shared.appendingPathComponent("two.png"))
        let source = """
        ![one](../shared/one.png)
        ![two][ref]

        [ref]: ../shared/two.png

        `![code](missing.png)`
        ```md
        ![fenced](missing.png)
        ```
        """
        let plan = try PortablePackagePlanner.plan(source: source,
            documentURL: docs.appendingPathComponent("README.md"))
        XCTAssertEqual(Set(plan.assets.map(\.relativePath)), ["assets/one.png", "assets/two.png"])
        XCTAssertTrue(plan.markdown.contains("![one](assets/one.png)"), plan.markdown)
        XCTAssertTrue(plan.markdown.contains("[ref]: assets/two.png"), plan.markdown)
        XCTAssertTrue(plan.markdown.contains("`![code](missing.png)`"), plan.markdown)
        XCTAssertTrue(plan.markdown.contains("![fenced](missing.png)"), plan.markdown)
    }

    func testPackageFolderAndZipKeepImageAndRejectDestinationCollision() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: image)
        let plan = try PortablePackagePlanner.plan(source: "![photo](photo.png)",
            documentURL: root.appendingPathComponent("README.md"))
        let folder = try PortablePackageExporter.export(plan, to: root, name: "book",
                                                       format: .markdown, zip: false)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("index.md"),
                                  encoding: .utf8), "![photo](assets/photo.png)")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("assets/photo.png")),
                       Data([1, 2, 3]))
        XCTAssertThrowsError(try PortablePackageExporter.export(plan, to: root, name: "book",
            format: .markdown, zip: false)) { error in
            XCTAssertEqual(error as? PortablePackageError, .destinationExists)
        }
        let archive = try PortablePackageExporter.export(plan, to: root, name: "book",
            format: .html, zip: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertGreaterThan(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 0)
    }

    func testMissingImageStopsBeforeWritingPackage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try PortablePackagePlanner.plan(source: "![lost](missing.png)",
            documentURL: root.appendingPathComponent("README.md"))) { error in
            XCTAssertEqual(error as? PortablePackageError, .missingResource("missing.png"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("book").path))
    }

    func testAttachmentLinksKeepFragmentsAndHTMLLinksPointInsidePackage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([5]).write(to: root.appendingPathComponent("guide.pdf"))
        let source = "[guide](guide.pdf#page=2) and [again][guide]\n\n[guide]: guide.pdf#page=3"
        let plan = try PortablePackagePlanner.plan(source: source,
            documentURL: root.appendingPathComponent("README.md"))
        XCTAssertEqual(plan.assets.map(\.relativePath), ["assets/guide.pdf"])
        XCTAssertTrue(plan.markdown.contains("[guide](assets/guide.pdf#page=2)"), plan.markdown)
        XCTAssertTrue(plan.markdown.contains("[guide]: assets/guide.pdf#page=3"), plan.markdown)
        XCTAssertTrue(plan.html.contains("href=\"assets/guide.pdf#page=2\""), plan.html)
        let folder = try PortablePackageExporter.export(plan, to: root, name: "share",
                                                       format: .html, zip: false)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("assets/guide.pdf")), Data([5]))
    }

    func testExternalImageFailsInsteadOfProducingIncompletePackage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try PortablePackagePlanner.plan(source: "![external](https://example.com/a.png)",
            documentURL: root.appendingPathComponent("README.md"))) { error in
            XCTAssertEqual(error as? PortablePackageError,
                           .externalImage("https://example.com/a.png"))
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("package-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
