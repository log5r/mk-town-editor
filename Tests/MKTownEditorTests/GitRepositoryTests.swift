import Foundation
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

    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments) failed")
    }
}
