import SwiftUI
import UIKit
import XCTest
@testable import MKTownEditorMobile

@MainActor
final class MobileWorkspaceTests: XCTestCase {
    private final class SearchBox: ObservableObject {
        @Published var state = MobileEditorState(presentation: .preview)
        @Published var text = "日本語🙂 日本語🙂"
    }

    private struct SearchContainer: View {
        @ObservedObject var model: SearchBox
        var body: some View {
            HStack {
                if model.state.presentation != .preview {
                    TextEditor(text: $model.text)
                        .modifier(MobileFindNavigator(editorState: $model.state))
                }
                if model.state.presentation == .preview {
                    ScrollView { Text(model.text) }.frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Search Test")
            .toolbar {
                Button("Find") { model.state.showFindNavigator() }
            }
        }
    }

    private final class AppearanceHost<Content: View>: UIHostingController<Content> {
        var didAppear = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            didAppear = true
        }
    }

    func testFindRequestPresentsNavigatorAfterLeavingPreview() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let model = SearchBox()
        let host = AppearanceHost(rootView: NavigationStack { SearchContainer(model: model) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<100 {
            if host.didAppear { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(host.didAppear)
        XCTAssertTrue(textViews(in: host.view).isEmpty)
        for cycle in 0..<2 {
            model.state.showFindNavigator()
            // UIKit presentation can follow the SwiftUI update by several animation frames.
            for _ in 0..<100 {
                if textViews(in: host.view).first?.findInteraction?.isFindNavigatorVisible == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let editor = try XCTUnwrap(textViews(in: host.view).first)
            XCTAssertNotNil(editor.window)
            XCTAssertGreaterThan(editor.bounds.width, 0)
            let interaction = try XCTUnwrap(editor.findInteraction)
            XCTAssertTrue(interaction.isFindNavigatorVisible, "Search cycle \(cycle)")
            XCTAssertTrue(model.state.showsFindNavigator, "Search cycle \(cycle)")
            model.state.togglePreview(showsEditor: true)
            for _ in 0..<100 {
                if textViews(in: host.view).isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertFalse(model.state.showsFindNavigator)
            XCTAssertNil(editor.window)
            XCTAssertTrue(textViews(in: host.view).isEmpty)
        }
    }

    func testNativeFindSupportsNavigationReplacementUndoAndDocumentSaving() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let model = DocumentBox()
        let original = "# 日本語🙂\n\ne\u{301} 日本語🙂 日本語🙂\n"
        model.document.text = original
        let host = UIHostingController(rootView: Container(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        XCTAssertTrue(editor.isFindInteractionEnabled)
        editor.becomeFirstResponder()
        let interaction = try XCTUnwrap(editor.findInteraction)
        interaction.presentFindNavigator(showingReplace: true)
        defer { interaction.dismissFindNavigator() }
        try await Task.sleep(for: .milliseconds(200))
        let session = try XCTUnwrap(interaction.activeFindSession)
        XCTAssertTrue(session.supportsReplacement)
        session.performSearch(query: "日本語🙂", options: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.resultCount, 3)
        interaction.findNext()
        let first = session.highlightedResultIndex
        interaction.findNext()
        XCTAssertNotEqual(session.highlightedResultIndex, first)
        interaction.findPrevious()
        XCTAssertEqual(session.highlightedResultIndex, first)

        session.performSingleReplacement(query: "日本語🙂", replacementString: "置換👩🏽‍💻", options: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.document.text.components(separatedBy: "置換👩🏽‍💻").count - 1, 1)
        XCTAssertEqual(model.document.text.components(separatedBy: "日本語🙂").count - 1, 2)
        editor.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.document.text, original)

        session.replaceAll(searchQuery: "日本語🙂", replacementString: "", options: nil)
        try await Task.sleep(for: .milliseconds(100))
        let replaced = "# \n\ne\u{301}  \n"
        XCTAssertEqual(model.document.text, replaced)
        XCTAssertEqual(try MarkdownDocument(data: model.document.encodedData()).text, replaced)
        editor.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.document.text, original)
        session.replaceAll(searchQuery: "missing", replacementString: "unused", options: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.document.text, original)
    }

    func testFindCountSurvivesRepeatedNavigationAndViewUpdates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let model = SearchBox()
        model.state = MobileEditorState(presentation: .editor)
        model.text = (1...40).map { "\($0). 日本語🙂 needle\n" }.joined()
        let original = model.text
        let host = AppearanceHost(rootView: NavigationStack { SearchContainer(model: model) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<100 where !host.didAppear { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(host.didAppear)
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        editor.findInteraction?.searchText = "日本語🙂"
        model.state.showFindNavigator()
        for _ in 0..<100 where editor.findInteraction?.isFindNavigatorVisible != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        let interaction = try XCTUnwrap(editor.findInteraction)
        let session = try XCTUnwrap(interaction.activeFindSession)
        defer { interaction.dismissFindNavigator() }
        session.performSearch(query: "日本語🙂", options: nil)
        for _ in 0..<100 where session.resultCount != 40 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(session.resultCount, 40)
        for _ in 0..<100 where scene.windows.flatMap({ findCountLabels(in: $0) }).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(scene.windows.flatMap { findCountLabels(in: $0) }.isEmpty)
        interaction.findNext()
        for _ in 0..<100 where session.highlightedResultIndex == NSNotFound {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue((0..<40).contains(session.highlightedResultIndex))
        for backwards in [false, true] {
            for step in 0..<85 {
                let previous = session.highlightedResultIndex
                if backwards { interaction.findPrevious() } else { interaction.findNext() }
                model.objectWillChange.send()
                host.view.layoutIfNeeded()
                await Task.yield()
                XCTAssertEqual(session.highlightedResultIndex, (previous + (backwards ? 39 : 1)) % 40,
                               "Navigation \(step), backwards: \(backwards)")
                XCTAssertEqual(session.resultCount, 40)
                XCTAssertTrue(interaction.isFindNavigatorVisible)
                XCTAssertTrue(interaction.activeFindSession === session)
                XCTAssertTrue(textViews(in: host.view).first === editor)
                XCTAssertFalse(scene.windows.flatMap { findCountLabels(in: $0) }.isEmpty,
                               "The result count disappeared during navigation \(step)")
            }
        }
        XCTAssertEqual(model.text, original)
        let labels = scene.windows.flatMap { findCountLabels(in: $0) }
        XCTAssertFalse(labels.isEmpty, "The native find navigator must keep its result count visible")
    }

    private func findCountLabels(in view: UIView) -> [String] {
        guard !view.isHidden, view.alpha > 0 else { return [] }
        let label = (view as? UILabel)?.text
        let own = label.map { $0.count < 40 && $0.contains("40") ? [$0] : [] } ?? []
        return own + view.subviews.flatMap { findCountLabels(in: $0) }
    }

    private final class PreferenceBox: ObservableObject {
        @Published var preserves = false
        @Published var shows = false
        @Published var formats = true
    }

    private struct PreferencesContainer: View {
        @ObservedObject var model: PreferenceBox
        var body: some View {
            MobilePreferencesView(preservesSoftLineBreaks: $model.preserves,
                showsFrontMatter: $model.shows, formatsFrontMatter: $model.formats)
        }
    }

    func testLineBreakPreferenceDefaultsOffPersistsAndKeepsFrontMatterChoices() throws {
        let suite = "MobileWorkspaceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = MarkdownDocument(text: "first\nsecond")
        XCTAssertFalse(MobileEditorWorkspace(document: .constant(document), preferences: defaults).preservesSoftLineBreaks)
        defaults.set(true, forKey: "mobile.showsFrontMatterInPreview")
        defaults.set(true, forKey: "mobile.formatsFrontMatterInPreview")
        for enabled in [true, false, true] {
            defaults.set(enabled, forKey: "mobile.preservesSoftLineBreaksInPreview")
            let restored = MobileEditorWorkspace(document: .constant(document), preferences: defaults)
            XCTAssertEqual(restored.preservesSoftLineBreaks, enabled)
            XCTAssertTrue(restored.showsFrontMatter)
            XCTAssertTrue(restored.formatsFrontMatter)
        }
        XCTAssertEqual(document.text, "first\nsecond")
    }

    func testSettingsControlsApplyImmediatelyAndRetainFormattingWhenHidden() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let model = PreferenceBox()
        let host = UIHostingController(rootView: PreferencesContainer(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        let controls = switches(in: host.view)
        XCTAssertEqual(controls.count, 3)
        guard controls.count == 3 else { return }
        XCTAssertFalse(controls[0].isOn)
        XCTAssertFalse(controls[1].isOn)
        XCTAssertTrue(controls[2].isOn)
        XCTAssertFalse(controls[2].isEnabled)
        controls[0].isOn = true
        controls[0].sendActions(for: .valueChanged)
        XCTAssertTrue(model.preserves)
        controls[1].isOn = true
        controls[1].sendActions(for: .valueChanged)
        XCTAssertTrue(model.shows)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(controls[2].isEnabled)
        controls[1].isOn = false
        controls[1].sendActions(for: .valueChanged)
        XCTAssertFalse(model.shows)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(controls[2].isEnabled)
        XCTAssertTrue(model.formats)
    }

    func testSettingsButtonPresentsScreenFromDocumentToolbar() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack {
            MobileEditorWorkspace(document: .constant(MarkdownDocument(text: "first\nsecond")))
        })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        func items(_ item: UINavigationItem) -> [UIBarButtonItem] {
            (item.rightBarButtonItems ?? []) + item.trailingItemGroups.flatMap(\.barButtonItems)
        }
        func toolbarItems(in controller: UIViewController) -> [UIBarButtonItem] {
            items(controller.navigationItem) + (controller.toolbarItems ?? []) +
                controller.children.flatMap { toolbarItems(in: $0) }
        }
        func viewItems(in view: UIView) -> [UIBarButtonItem] {
            let own = (view as? UINavigationBar)?.items?.flatMap { items($0) } ??
                (view as? UIToolbar)?.items ?? []
            return own + view.subviews.flatMap { viewItems(in: $0) }
        }
        let buttons = toolbarItems(in: host) + viewItems(in: host.view)
        // iOS 27.0 exposes the SwiftUI button's accessibility metadata on its view,
        // rather than on UIBarButtonItem. The trailing action is Settings; verify
        // the presented controls as well so another sheet cannot satisfy this test.
        let settings = try XCTUnwrap(buttons.first { $0.accessibilityIdentifier == "openSettings" ||
            $0.accessibilityLabel == String(localized: "設定") } ?? buttons.last)
        let action = try XCTUnwrap(settings.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: settings.target, from: settings, for: nil))
        try await Task.sleep(for: .milliseconds(400))
        let presented = try XCTUnwrap(host.presentedViewController)
        XCTAssertEqual(switches(in: presented.view).count, 3)
        host.dismiss(animated: false)
    }

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

    private func switches(in view: UIView) -> [UISwitch] {
        (view as? UISwitch).map { [$0] } ?? view.subviews.flatMap { switches(in: $0) }
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
