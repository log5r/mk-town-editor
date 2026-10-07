import AppKit
import XCTest
@testable import MKTownEditor

@MainActor
final class ExternalDiagramRendererTests: XCTestCase {
    func testLanguageMappingAndMissingDependency() async {
        XCTAssertEqual(ExternalDiagramKind(language: "dot"), .graphviz)
        XCTAssertEqual(ExternalDiagramKind(language: "graphviz"), .graphviz)
        XCTAssertEqual(ExternalDiagramKind(language: "puml"), .plantuml)
        XCTAssertNil(ExternalDiagramKind(language: "swift"))
        let config = ExternalDiagramConfiguration(graphvizExecutable: "", plantUMLJar: "")
        do {
            _ = try await ExternalDiagramRenderer.render("digraph { A -> B }", kind: .graphviz,
                                                          configuration: config)
            XCTFail("A tool must be configured")
        } catch {
            XCTAssertEqual(error as? ExternalDiagramError, .notConfigured)
        }
        let input = URL(fileURLWithPath: "/tmp/source with spaces.puml")
        let output = URL(fileURLWithPath: "/tmp/result.png")
        let command = ExternalDiagramCommand.make(kind: .plantuml,
            toolPath: "/tmp/plant uml.jar", input: input, output: output)
        XCTAssertEqual(command.executable, "/usr/bin/java")
        XCTAssertEqual(command.securityProfile, "SANDBOX")
        XCTAssertEqual(command.arguments.prefix(3),
                       ["-DPLANTUML_SECURITY_PROFILE=SANDBOX", "-jar", "/tmp/plant uml.jar"])
        XCTAssertTrue(command.arguments.contains("-pipe"))
    }

    func testSuccessfulRenderIsCachedBySourceAndToolIdentity() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(testPNG())
        try png.write(to: directory.appendingPathComponent("reference.png"))
        let script = try executable(in: directory, body: """
            echo render >> "$(dirname "$0")/calls.txt"
            cp "$(dirname "$0")/reference.png" "$4"
            """)
        let config = ExternalDiagramConfiguration(graphvizExecutable: script.path, plantUMLJar: "")
        for _ in 0..<3 { _ = try await ExternalDiagramRenderer.render("digraph { A -> B }", kind: .graphviz, configuration: config) }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls.txt"), encoding: .utf8), "render\n")
        _ = try await ExternalDiagramRenderer.render("digraph { B -> C }", kind: .graphviz, configuration: config)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls.txt"), encoding: .utf8), "render\nrender\n")
    }

    func testGraphvizArgumentsUseSourceFileWithoutShellExpansion() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try XCTUnwrap(testPNG())
        try png.write(to: directory.appendingPathComponent("reference.png"))
        let script = try executable(in: directory, body: """
            [ "$1" = "-Tpng" ] || exit 5
            [ "$3" = "-o" ] || exit 6
            cat "$2" > "$(dirname "$0")/captured.txt"
            cp "$(dirname "$0")/reference.png" "$4"
            """)
        let source = "digraph { A -> B [label=\"$(touch should-not-run)\"] }"
        let config = ExternalDiagramConfiguration(graphvizExecutable: script.path, plantUMLJar: "")
        let output = try await ExternalDiagramRenderer.render(source, kind: .graphviz,
                                                               configuration: config)
        XCTAssertEqual(output, png)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("captured.txt"),
                                  encoding: .utf8), source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-run").path))
    }

    func testTimeoutAndCancellationTerminateRenderer() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try executable(in: directory, body: "exec sleep 5")
        let config = ExternalDiagramConfiguration(graphvizExecutable: script.path, plantUMLJar: "")
        do {
            _ = try await ExternalDiagramRenderer.render("digraph {}", kind: .graphviz,
                                                          configuration: config, timeout: 0.1)
            XCTFail("Renderer should time out")
        } catch {
            XCTAssertEqual(error as? ExternalDiagramError, .timedOut)
        }
        let task = Task {
            try await ExternalDiagramRenderer.render("digraph {}", kind: .graphviz,
                                                     configuration: config, timeout: 5)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Renderer should stop after cancellation")
        } catch {
            XCTAssertEqual(error as? ExternalDiagramError, .cancelled)
        }
    }

    func testInstalledGraphvizProducesPNGWhenAvailable() async throws {
        let candidates = ["/opt/homebrew/bin/dot", "/usr/local/bin/dot", "/usr/bin/dot"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("Graphviz is optional")
        }
        let config = ExternalDiagramConfiguration(graphvizExecutable: executable, plantUMLJar: "")
        let image = try await ExternalDiagramRenderer.render("digraph { A -> B }", kind: .graphviz,
                                                              configuration: config)
        XCTAssertNotNil(NSBitmapImageRep(data: image))
    }

    func testRendererFailureShowsStandardError() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = try executable(in: directory, body: "echo 'syntax error on line 2' >&2\nexit 2")
        let config = ExternalDiagramConfiguration(graphvizExecutable: script.path, plantUMLJar: "")
        do {
            _ = try await ExternalDiagramRenderer.render("digraph {", kind: .graphviz,
                                                          configuration: config)
            XCTFail("The renderer must report failure")
        } catch {
            guard case let ExternalDiagramError.failed(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("syntax error on line 2"))
        }
    }

    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executable(in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent("renderer with spaces.sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func testPNG() -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.setColor(.red, atX: 0, y: 0)
        return rep.representation(using: .png, properties: [:])
    }
}
