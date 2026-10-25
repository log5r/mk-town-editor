import SwiftUI
import UIKit
import XCTest
@testable import MKTownEditorMobile

@MainActor
final class MobileWorkspaceTests: XCTestCase {
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
