import Foundation
import XCTest
@testable import MKTownEditor

final class ExternalDocumentConverterTests: XCTestCase {
    func testFormatArgumentsAndToolDiscovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pandoc-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("pandoc")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: executable.path)
        XCTAssertEqual(ExternalDocumentConverter.findPandoc(environment: ["PATH": root.path]),
                       executable)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let linked = bin.appendingPathComponent("pandoc")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: executable)
        XCTAssertEqual(ExternalDocumentConverter.findPandoc(environment: ["PATH": bin.path]),
                       linked)
        let values = ExternalDocumentConverter.arguments(
            input: root.appendingPathComponent("input.md"),
            output: root.appendingPathComponent("out.epub"), format: .epub,
            resourceDirectory: root, dialect: .basic)
        XCTAssertEqual(values[0...3], ["-f", "commonmark", "-t", "epub3"])
        XCTAssertTrue(values.contains("--resource-path"))
        XCTAssertTrue(values.contains(root.path))
    }

    func testSuccessfulConversionUsesTemporaryOutputAndPreservesMarkdownSource() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeExecutable(in: root, body: #"""
        output=''
        input=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '-o' ]; then shift; output="$1"
          else input="$1"; fi
          shift
        done
        cp "$input" "$output"
        """#)
        let destination = root.appendingPathComponent("output.docx")
        try Data("previous".utf8).write(to: destination)
        let sourceURL = root.appendingPathComponent("source.md")
        try Data("disk original".utf8).write(to: sourceURL)

        try ExternalDocumentConverter.convert("# Unsaved edit", documentURL: sourceURL,
            destination: destination, format: .docx, dialect: .extended,
            executable: executable)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "# Unsaved edit")
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "disk original")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path)
            .contains { $0.hasPrefix(".mktown-output-") })
    }

    func testFailureKeepsExistingDestinationAndReportsConverterMessage() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeExecutable(in: root, body: #"""
        echo 'unsupported format' >&2
        exit 23
        """#)
        let destination = root.appendingPathComponent("output.odt")
        try Data("previous".utf8).write(to: destination)
        XCTAssertThrowsError(try ExternalDocumentConverter.convert("# Source",
            documentURL: nil, destination: destination, format: .odt,
            dialect: .extended, executable: executable)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsupported format"))
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
        XCTAssertThrowsError(try ExternalDocumentConverter.convert("# Source",
            documentURL: nil, destination: destination, format: .odt,
            dialect: .extended, executable: root.appendingPathComponent("missing")))
    }

    func testCancellationTerminatesConverterAndKeepsDestination() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeExecutable(in: root, body: #"""
        sleep 2
        """#)
        let destination = root.appendingPathComponent("output.epub")
        try Data("previous".utf8).write(to: destination)
        let worker = Task.detached {
            try ExternalDocumentConverter.convert("# Source", documentURL: nil,
                destination: destination, format: .epub, dialect: .extended,
                executable: executable)
        }
        try await Task.sleep(for: .milliseconds(150))
        worker.cancel()
        do {
            try await worker.value
            XCTFail("Cancelled conversion unexpectedly completed")
        } catch {
            XCTAssertEqual(error as? ExternalConversionError, .cancelled)
        }
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
    }

    func testCancellationKillsConverterThatIgnoresTermination() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let started = root.appendingPathComponent("started")
        let executable = try makeExecutable(in: root, body: """
        trap '' TERM
        printf '%s' $$ > "\(started.path)"
        exec /bin/sleep 30
        """)
        let destination = root.appendingPathComponent("output.epub")
        try Data("previous".utf8).write(to: destination)
        let worker = Task.detached {
            try ExternalDocumentConverter.convert("# Source", documentURL: nil,
                destination: destination, format: .epub, dialect: .extended, executable: executable)
        }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let pid = try XCTUnwrap(Int32(try String(contentsOf: started, encoding: .utf8)))
        XCTAssertEqual(Darwin.kill(pid, 0), 0, "converter must be running before cancellation")
        let cancelledAt = ContinuousClock.now
        worker.cancel()
        do { try await worker.value; XCTFail("Cancelled conversion unexpectedly completed") }
        catch { XCTAssertEqual(error as? ExternalConversionError, .cancelled) }
        XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(2))
        XCTAssertNotEqual(Darwin.kill(pid, 0), 0, "cancellation must reap a converter that ignores SIGTERM")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "previous")
    }

    func testZeroExitWithoutOutputIsReportedClearly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try makeExecutable(in: root, body: "exit 0\n")
        let destination = root.appendingPathComponent("output.docx")
        XCTAssertThrowsError(try ExternalDocumentConverter.convert("text",
            documentURL: nil, destination: destination, format: .docx,
            dialect: .extended, executable: executable)) { error in
            XCTAssertEqual(error as? ExternalConversionError, .emptyOutput)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pandoc-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeExecutable(in root: URL, body: String) throws -> URL {
        let url = root.appendingPathComponent("fake-pandoc")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: url.path)
        return url
    }
}
