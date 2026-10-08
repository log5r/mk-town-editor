import Foundation
import SwiftUI
import XCTest
@testable import MKTownEditor

final class GitRepositoryTests: XCTestCase {
    func testReadsStatusDiffHistoryAndOldVersionWithoutShell() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try git(["init", "--quiet"], in: folder)
        let document = folder.appendingPathComponent("note; touch should-not-exist.md")
        try "old\n".write(to: document, atomically: true, encoding: .utf8)
        try git(["add", "--", document.lastPathComponent], in: folder)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--quiet", "-m", "Initial"], in: folder)
        try "new\n".write(to: document, atomically: true, encoding: .utf8)

        let snapshot = try GitRepository.load(for: document)
        XCTAssertEqual(snapshot.rootURL, folder.standardizedFileURL)
        XCTAssertEqual(snapshot.relativePath, document.lastPathComponent)
        XCTAssertTrue(snapshot.status.contains("note; touch should-not-exist.md"))
        XCTAssertTrue(snapshot.diff.contains("-old"))
        XCTAssertTrue(snapshot.diff.contains("+new"))
        XCTAssertEqual(snapshot.history.count, 1)
        XCTAssertEqual(snapshot.history[0].subject, "Initial")
        XCTAssertEqual(try GitRepository.content(of: snapshot.history[0], in: snapshot), "old\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("should-not-exist.md").path))
    }

    func testRejectsFilesOutsideGitAndUnlistedRevisions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertThrowsError(try GitRepository.load(for: folder.appendingPathComponent("note.md")))
        try git(["init", "--quiet"], in: folder)
        let document = folder.appendingPathComponent("note.md")
        try "body".write(to: document, atomically: true, encoding: .utf8)
        let snapshot = try GitRepository.load(for: document)
        XCTAssertTrue(snapshot.history.isEmpty)
        XCTAssertThrowsError(try GitRepository.content(of:
            GitRevision(hash: String(repeating: "a", count: 40), shortHash: "aaaa", subject: "Fake"),
            in: snapshot))
    }

    func testDocumentsReachedThroughSymbolicLinksAreFoundInTheirRepository() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("repository")
        let chapters = folder.appendingPathComponent("book/chapters")
        try FileManager.default.createDirectory(at: chapters, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try git(["init", "--quiet"], in: folder)
        try git(["config", "user.name", "Test"], in: folder)
        try git(["config", "user.email", "test@example.invalid"], in: folder)
        try "body\n".write(to: chapters.appendingPathComponent("one.md"), atomically: true, encoding: .utf8)
        try git(["add", "--", "book/chapters/one.md"], in: folder)
        try git(["commit", "--quiet", "-m", "Add chapter"], in: folder)
        let link = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let linkedChapters = base.appendingPathComponent("chapters-link")
        try FileManager.default.createSymbolicLink(at: linkedChapters, withDestinationURL: chapters)

        for document in [link.appendingPathComponent("book/chapters/one.md"),
                         linkedChapters.appendingPathComponent("one.md")] {
            let snapshot = try GitRepository.load(for: document)
            XCTAssertEqual(snapshot.relativePath, "book/chapters/one.md")
            XCTAssertEqual(snapshot.history.first?.subject, "Add chapter")
            XCTAssertEqual(try GitRepository.content(of: snapshot.history[0], in: snapshot), "body\n")
        }
    }

    func testStagesUnstagesAndCommitsOnlyReviewedIndex() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try git(["init", "--quiet"], in: folder)
        let first = folder.appendingPathComponent("first.md")
        let second = folder.appendingPathComponent("second.md")
        try "old".write(to: first, atomically: true, encoding: .utf8)
        try "old".write(to: second, atomically: true, encoding: .utf8)
        try git(["add", "--", "first.md", "second.md"], in: folder)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                 "commit", "--quiet", "-m", "Base"], in: folder)
        try "new".write(to: first, atomically: true, encoding: .utf8)
        try "new".write(to: second, atomically: true, encoding: .utf8)
        try GitRepository.stage(["first.md"], in: folder)
        XCTAssertTrue(try GitRepository.diff(for: "first.md", in: folder, staged: true).contains("+new"))
        XCTAssertTrue(try GitRepository.diff(for: "second.md", in: folder, staged: true).isEmpty)
        try GitRepository.unstage(["first.md"], in: folder)
        XCTAssertFalse(try GitRepository.statusEntries(in: folder).contains(where: \.isStaged))
        try git(["config", "user.name", "Test"], in: folder)
        try git(["config", "user.email", "test@example.invalid"], in: folder)
        try GitRepository.stage(["first.md"], in: folder)
        try GitRepository.commit(message: "Update first", in: folder)
        let entries = try GitRepository.statusEntries(in: folder)
        XCTAssertEqual(entries.map(\.path), ["second.md"])
        XCTAssertFalse(entries[0].isStaged)
        XCTAssertEqual(try GitRepository.load(for: first).history.first?.subject, "Update first")
    }

    func testConflictStatusIsSeparatedFromOrdinaryStage() {
        let entries = GitRepository.parseStatus("UU conflict.md\0 M normal.md\0")
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries[0].isConflicted)
        XCTAssertFalse(entries[0].isStaged)
        XCTAssertFalse(entries[1].isConflicted)
        XCTAssertFalse(entries[1].isStaged)
    }

    func testConflictRequiresSavedResolutionBeforeStaging() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try git(["init", "--quiet"], in: folder)
        try git(["config", "user.name", "Test"], in: folder)
        try git(["config", "user.email", "test@example.invalid"], in: folder)
        let file = folder.appendingPathComponent("conflict.md")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "--", "conflict.md"], in: folder)
        try git(["commit", "--quiet", "-m", "Base"], in: folder)
        try git(["checkout", "--quiet", "-b", "side"], in: folder)
        try "side\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["commit", "--quiet", "-am", "Side"], in: folder)
        try git(["checkout", "--quiet", "-"], in: folder)
        try "main\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["commit", "--quiet", "-am", "Main"], in: folder)
        try git(["merge", "side"], in: folder, expectedStatus: 1)
        XCTAssertTrue(try GitRepository.statusEntries(in: folder)[0].isConflicted)
        XCTAssertThrowsError(try GitRepository.stage(["conflict.md"], in: folder))
        XCTAssertThrowsError(try GitRepository.stageResolvedConflict("conflict.md", in: folder))
        try "resolved\n".write(to: file, atomically: true, encoding: .utf8)
        try GitRepository.stageResolvedConflict("conflict.md", in: folder)
        XCTAssertFalse(try GitRepository.statusEntries(in: folder)[0].isConflicted)
    }

    private func git(_ arguments: [String], in folder: URL, expectedStatus: Int32 = 0) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, expectedStatus, "git \(arguments) failed")
    }

    func testDiffPresentationColorsChangedLinesWithoutPerLineViews() {
        let diff = "diff --git a/a.md b/a.md\n--- a/a.md\n+++ b/a.md\n@@ -1,2 +1,2 @@\n-古い行\n+新しい行🙂\n 文脈\n"
        let presentation = GitDiffPresentation(diff)
        let text = presentation.text as NSString
        XCTAssertEqual(presentation.text, diff)
        XCTAssertEqual(presentation.totalLines, 7)
        XCTAssertFalse(presentation.isTruncated)
        XCTAssertEqual(presentation.deletions.map(text.substring(with:)), ["-古い行"])
        XCTAssertEqual(presentation.additions.map(text.substring(with:)), ["+新しい行🙂"])
        let plain = GitDiffPresentation("- list item\n+ plus", highlightsChanges: false)
        XCTAssertTrue(plain.additions.isEmpty && plain.deletions.isEmpty)
        XCTAssertEqual(GitDiffPresentation("").totalLines, 0)
    }

    func testLargeDiffIsTruncatedUntilFullDisplayIsRequested() {
        let diff = (0..<60_000).map { $0.isMultiple(of: 2) ? "+added \($0)" : "-removed \($0)" }
            .joined(separator: "\n")
        let start = Date()
        let truncated = GitDiffPresentation(diff)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(truncated.isTruncated)
        XCTAssertEqual(truncated.totalLines, 60_000)
        XCTAssertEqual(truncated.shownLines, GitDiffPresentation.defaultLineLimit)
        XCTAssertEqual(truncated.additions.count + truncated.deletions.count, GitDiffPresentation.defaultLineLimit)
        XCTAssertTrue(truncated.text.hasSuffix("-removed \(GitDiffPresentation.defaultLineLimit - 1)\n"))
        let full = GitDiffPresentation(diff, lineLimit: nil)
        XCTAssertFalse(full.isTruncated)
        XCTAssertEqual(full.text, diff)
        XCTAssertEqual(full.additions.count, 30_000)
    }
}


@MainActor
final class GitDiffViewTests: XCTestCase {
    func testLargeDiffLaysOutWithoutBuildingRowViews() throws {
        let diff = (0..<60_000).map { "+line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
        let host = NSHostingView(rootView: GitDiffView(diff: diff, placeholder: "")
            .frame(width: 600, height: 400))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let start = Date()
        host.layoutSubtreeIfNeeded()
        host.display()
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let textView = try XCTUnwrap(Self.textView(in: host))
        XCTAssertEqual(textView.string.split(separator: "\n").count, GitDiffPresentation.defaultLineLimit)
        XCTAssertEqual(textView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                       .systemGreen)
    }

    private static func textView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = textView(in: subview) { return found }
        }
        return nil
    }
}
