import SwiftUI
import UIKit
import XCTest
@testable import MKTownEditorMobile

@MainActor
final class MobileWorkspaceTests: XCTestCase {
    func testFrontMatterPreferencesDefaultOffPersistAndRemainIndependent() throws {
        let suite = "MobileWorkspaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = MarkdownDocument(text: "---\ntags: [journal]\n---\n# Body")
        let workspace = MobileEditorWorkspace(document: .constant(document), preferences: defaults)
        XCTAssertFalse(workspace.showsFrontMatter)
        XCTAssertFalse(workspace.formatsFrontMatter)
        defaults.set(true, forKey: "mobile.showsFrontMatterInPreview")
        defaults.set(true, forKey: "mobile.formatsFrontMatterInPreview")
        let restored = MobileEditorWorkspace(document: .constant(document), preferences: defaults)
        XCTAssertTrue(restored.showsFrontMatter)
        XCTAssertTrue(restored.formatsFrontMatter)
        defaults.set(false, forKey: "mobile.showsFrontMatterInPreview")
        let hidden = MobileEditorWorkspace(document: .constant(document), preferences: defaults)
        XCTAssertFalse(hidden.showsFrontMatter)
        XCTAssertTrue(hidden.formatsFrontMatter)
        defaults.set(false, forKey: "mobile.formatsFrontMatterInPreview")
        XCTAssertFalse(MobileEditorWorkspace(document: .constant(document), preferences: defaults).formatsFrontMatter)
        XCTAssertEqual(document.text, "---\ntags: [journal]\n---\n# Body")
    }

    func testFrontMatterCardWrapsInNarrowLayoutAndScalesWithDynamicType() throws {
        let preview = MobileMarkdownPreview("---\ntitle: A long note title with enough words to wrap in a narrow preview pane\ntags: [journal, personal, project/app]\n---\n")
        let raw = try XCTUnwrap(preview.frontMatter?.raw)
        func size(width: CGFloat, type: DynamicTypeSize, formatted: Bool = true) -> CGSize {
            let host = UIHostingController(rootView: MobileFrontMatterPreviewView(raw: raw,
                rows: preview.frontMatterRows, formatsProperties: formatted).environment(\.dynamicTypeSize, type))
            return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
        }
        let narrow = size(width: 280, type: .large)
        XCTAssertLessThanOrEqual(narrow.width, 280)
        XCTAssertGreaterThan(narrow.height, size(width: 700, type: .large).height)
        XCTAssertGreaterThan(size(width: 280, type: .accessibility3).height, narrow.height)
        XCTAssertGreaterThan(size(width: 280, type: .large, formatted: false).height, 0)
    }

    private final class DocumentBox: ObservableObject {
        @Published var document = MarkdownDocument(text: "# Original\n\n日本語🙂\n")
    }

    private struct Container: View {
        @ObservedObject var model: DocumentBox
        var body: some View { MobileEditorWorkspace(document: $model.document) }
    }

    func testEditingSurvivesRepeatedContentResizingWithoutReplacingTheEditor() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let parent = UIViewController()
        let model = DocumentBox()
        let host = UIHostingController(rootView: Container(model: model))
        window.rootViewController = parent
        parent.addChild(host)
        parent.view.addSubview(host.view)
        host.didMove(toParent: parent)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        editor.becomeFirstResponder()
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("Edited on Duo\n")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.document.text.hasSuffix("Edited on Duo\n"))
        let edited = model.document.text
        let selection = editor.selectedRange

        for width in [960.0, 500, 720, 390] {
            host.view.frame.size.width = width
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let current = try XCTUnwrap(textViews(in: host.view).first)
            XCTAssertTrue(current === editor, "Resizing should preserve TextEditor's input session")
            XCTAssertEqual(current.selectedRange, selection)
            XCTAssertEqual(model.document.text, edited)
            XCTAssertEqual(try MarkdownDocument(data: model.document.encodedData()).text, edited)
        }
    }

    private func textViews(in view: UIView) -> [UITextView] {
        (view as? UITextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }

    func testWorkspaceDoesNotAddAnotherNavigationBarInsideDocumentNavigation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Container(model: DocumentBox()))
        let navigation = UINavigationController(rootViewController: host)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        func bars(in view: UIView) -> [UINavigationBar] {
            (view as? UINavigationBar).map { [$0] } ?? view.subviews.flatMap { bars(in: $0) }
        }
        XCTAssertEqual(bars(in: navigation.view).count, 1)
    }
}
