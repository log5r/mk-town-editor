import Foundation
import XCTest
@testable import MKTownEditor

@MainActor
final class DeclarativeExtensionTests: XCTestCase {
    private let validJSON = """
    {"schemaVersion":1,"id":"example.notes","name":"Notes",
     "theme":{"name":"Night","background":"#000000","body":"#FFFFFF",
       "heading":"#FFFFFF","code":"#FFFFFF","link":"#FFFFFF",
       "codeBackground":"#000000"},
     "snippets":[{"trigger":"sig","template":"${1:名前}$0"}]}
    """

    func testImportPersistsThemeAndStableSnippetIdentifiers() throws {
        let folder = FileManager.default.temporaryDirectory
        let file = folder.appendingPathComponent(UUID().uuidString + ".json")
        try validJSON.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let package = try DeclarativeExtension.load(from: file)
        XCTAssertEqual(package.id, "example.notes")
        XCTAssertEqual(package.snippets.count, 1)
        XCTAssertEqual(package.theme?.name, "Night")
        var settings = AppEditorSettings()
        settings.extensionPackages = [package]
        settings.previewTheme = .extensionTheme(try XCTUnwrap(package.theme))
        let restored = try JSONDecoder().decode(AppEditorSettings.self,
            from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.previewTheme, settings.previewTheme)
        XCTAssertEqual(restored.effectiveSnippets.first?.id, package.snippets.first?.id)
        XCTAssertEqual(restored.effectiveSnippets.first?.template, "${1:名前}$0")
        XCTAssertEqual(restored.previewTheme?.colorScheme, .dark)
        XCTAssertEqual(try JSONDecoder().decode(PreviewTheme.self,
            from: Data("\"paper\"".utf8)), .paper)
    }

    func testRejectsLowContrastAndInvalidSnippet() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try validJSON.replacingOccurrences(of: "#FFFFFF", with: "#111111")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DeclarativeExtension.load(from: file))
        try validJSON.replacingOccurrences(of: "\"sig\"", with: "\"bad trigger\"")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DeclarativeExtension.load(from: file))
    }

    func testRejectsOversizedPackage() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        try String(repeating: "x", count: 100_001).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try DeclarativeExtension.load(from: file))
    }

    func testInvalidPersistedThemeFallsBackWithoutCrashing() throws {
        let json = """
        {"name":"Broken","background":"invalid","body":"#FFFFFF",
         "heading":"#FFFFFF","code":"#FFFFFF","link":"#FFFFFF",
         "codeBackground":"#000000"}
        """
        let theme = try JSONDecoder().decode(DeclarativeExtension.Theme.self, from: Data(json.utf8))
        let rendered = NSAttributedString(string: "text")
        XCTAssertEqual(PreviewTypography.themed(rendered, kind: .paragraph,
            theme: .extensionTheme(theme)).string, "text")
        XCTAssertNil(PreviewTheme.extensionTheme(theme).background)
    }
}
