import Foundation
import Darwin
import XCTest
@testable import MKTownEditor

@MainActor
final class PortablePackageExporterTests: XCTestCase {
    func testCancellationDuringSlowAssetCopyRemovesPartialTargetAndStaging() async throws {
        for zip in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let source = root.appendingPathComponent("large.bin")
            let contents = Data(repeating: 0x5A, count: PortablePackageExporter.assetCopyChunkSize * 8)
            try contents.write(to: source)
            let gate = AssetCopyGate()
            defer { gate.release.signal() }
            let plan = PortablePackagePlan(markdown: "body", html: "<p>body</p>",
                assets: [PortablePackageAsset(sourceURL: source, relativePath: "assets/large.bin")])
            let task = Task {
                try await DocumentWork.commit {
                    try PortablePackageExporter.export(plan, to: root, name: "book", format: .markdown, zip: zip,
                        copyAsset: { source, target in
                            try PortablePackageExporter.copyAsset(from: source, to: target) { copied in
                                gate.record(target: target, copied: copied)
                                _ = gate.release.wait(timeout: .now() + 5)
                            }
                        })
                }
            }
            defer { task.cancel() }
            for _ in 0..<200 where gate.progress == nil { try await Task.sleep(for: .milliseconds(5)) }
            let progress = try XCTUnwrap(gate.progress, "wait until real bytes have been copied")
            XCTAssertEqual(try Data(contentsOf: progress.target).count, PortablePackageExporter.assetCopyChunkSize)
            XCTAssertLessThan(progress.copied, contents.count)
            let cancelledAt = ContinuousClock.now
            task.cancel()
            gate.release.signal()
            do { _ = try await task.value; XCTFail("Expected cancellation during asset copying") }
            catch { XCTAssertEqual(error as? PortablePackageError, .cancelled) }
            XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(2))
            XCTAssertEqual(gate.progress?.copied, PortablePackageExporter.assetCopyChunkSize,
                           "cancelled copying must not continue through the remaining attachment")
            XCTAssertFalse(FileManager.default.fileExists(atPath: progress.target.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(zip ? "book.zip" : "book").path))
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".mktown-") })
            XCTAssertEqual(try Data(contentsOf: source), contents)
        }
    }

    func testChunkedAssetCopyPreservesContentsAndFilePropertiesAndRejectsExistingTarget() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("attachment.bin"), target = root.appendingPathComponent("copied.bin")
        let contents = Data((0..<(PortablePackageExporter.assetCopyChunkSize * 2 + 37)).map { UInt8($0 % 251) })
        try contents.write(to: source)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let fork = Data(repeating: 0x41, count: 4_096)
        XCTAssertEqual(fork.withUnsafeBytes { setxattr(source.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }, 0)
        try FileManager.default.setAttributes([.modificationDate: date, .posixPermissions: 0o640], ofItemAtPath: source.path)
        try PortablePackageExporter.copyAsset(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: target), contents)
        var copiedFork = Data(count: fork.count)
        let forkBytes = copiedFork.withUnsafeMutableBytes {
            getxattr(target.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0)
        }
        XCTAssertEqual(forkBytes, fork.count)
        XCTAssertEqual(copiedFork, fork)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, date)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertThrowsError(try PortablePackageExporter.copyAsset(from: source, to: target))
        XCTAssertEqual(try Data(contentsOf: target), contents, "a failed exclusive create must not delete existing data")
        let empty = root.appendingPathComponent("empty.bin"), emptyCopy = root.appendingPathComponent("empty-copy.bin")
        try Data().write(to: empty)
        try PortablePackageExporter.copyAsset(from: empty, to: emptyCopy)
        XCTAssertEqual(try Data(contentsOf: emptyCopy), Data())
    }

    func testCancellationDuringArchiveCreationTerminatesChildAndRemovesTemporaryOutput() async throws {
        // Also cover a child that ignores SIGTERM so cancellation stays bounded.
        for ignoresTermination in [false, true] {
            let root = try makeRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("slow-archive")
            let started = root.appendingPathComponent("started")
            let trap = ignoresTermination ? "trap '' TERM\n" : ""
            let script = "#!/bin/sh\n" + trap + "printf 'partial archive' > \"$4\"\n" +
                ChildProcessFixture.publishPID(to: started) + "\nexec /bin/sleep 30\n"
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let plan = PortablePackagePlan(markdown: "body", html: "<p>body</p>", assets: [])
            let task = Task {
                try await DocumentWork.commit {
                    try PortablePackageExporter.export(plan, to: root, name: "book", format: .markdown,
                        zip: true, archiveExecutable: executable)
                }
            }
            var startedPID: pid_t?
            defer { task.cancel(); ChildProcessFixture.reap(startedPID) }
            startedPID = try await ChildProcessFixture.waitForPID(at: started)
            let pid = try XCTUnwrap(startedPID)
            XCTAssertTrue(ChildProcessFixture.isRunning(pid), "Archive child must be running before cancellation")
            let cancellationStarted = ContinuousClock.now
            task.cancel()
            do { _ = try await task.value; XCTFail("Expected archive cancellation") }
            catch { XCTAssertEqual(error as? PortablePackageError, .cancelled) }
            XCTAssertLessThan(cancellationStarted.duration(to: .now), .seconds(2))
            XCTAssertFalse(ChildProcessFixture.isRunning(pid), "Cancellation must reap the archive child")
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

    // Issue #41: the HTML body used to embed base64 images that were also copied to assets/,
    // and linked media through absolute file: URLs that broke once the package moved.
    func testHTMLPackageReferencesCopiedAssetsInsteadOfEmbeddingThem() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Data(repeating: 0x89, count: 64 * 1_024)
        try image.write(to: root.appendingPathComponent("my photo.png"))
        try Data([7]).write(to: root.appendingPathComponent("voice.m4a"))
        let source = "![photo](my%20photo.png)\n\n![again][ref]\n\n[ref]: my%20photo.png\n\n!audio[Voice](voice.m4a)"
        let plan = try PortablePackagePlanner.plan(source: source,
            documentURL: root.appendingPathComponent("README.md"))
        XCTAssertEqual(Set(plan.assets.map(\.relativePath)), ["assets/my photo.png", "assets/voice.m4a"])
        XCTAssertTrue(plan.html.contains("<img src=\"assets/my%20photo.png\" alt=\"photo\">"), plan.html)
        XCTAssertTrue(plan.html.contains("<img src=\"assets/my%20photo.png\" alt=\"again\">"), plan.html)
        XCTAssertTrue(plan.html.contains("<a href=\"assets/voice.m4a\">音声: Voice</a>"), plan.html)
        XCTAssertFalse(plan.html.contains("data:image/png"))
        XCTAssertFalse(plan.html.contains("file:"))
        XCTAssertFalse(plan.html.contains(root.path))
        let folder = try PortablePackageExporter.export(plan, to: root, name: "share",
                                                       format: .html, zip: false)
        let index = try Data(contentsOf: folder.appendingPathComponent("index.html"))
        XCTAssertLessThan(index.count, image.count / 4, "index.html must not carry a second copy of the image")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("assets/my photo.png")), image)
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

private final class AssetCopyGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: (target: URL, copied: Int)?
    var progress: (target: URL, copied: Int)? { lock.lock(); defer { lock.unlock() }; return value }
    func record(target: URL, copied: Int) {
        lock.lock(); defer { lock.unlock() }
        value = (target, copied)
    }
}
