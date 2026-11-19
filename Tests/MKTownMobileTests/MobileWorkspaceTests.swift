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
        @State private var selection = MobileTextSelection()
        @State private var focused = false
        var body: some View {
            HStack {
                if model.state.presentation != .preview {
                    MobileMarkdownTextView(text: $model.text, selection: selection, isFocused: $focused,
                        isFindNavigatorPresented: $model.state.showsFindNavigator)
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
                try await Task.sleep(for: .milliseconds(50))
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
        guard !view.isHidden, view.alpha > 0, view.bounds.width > 0, view.bounds.height > 0 else { return [] }
        let label = (view as? UILabel)?.text
        let own = label.map { $0.count < 40 && $0.contains("40") ? [$0] : [] } ?? []
        return own + view.subviews.flatMap { findCountLabels(in: $0) }
    }

    func testWorkspaceFindCountSurvivesNavigationInLongDocument() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let model = DocumentBox()
        let searchTerm = "検索対象"
        model.document.text = (1...40).map {
            "## テスト区間\($0)\n\n" + String(repeating: "これは表示検証用に生成したデータです。", count: 15)
                + " \(searchTerm)\n\n"
        }.joined()
        let original = model.document.text
        let host = AppearanceHost(rootView: NavigationStack { Container(model: model) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<100 where !host.didAppear { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(200))
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        editor.findInteraction?.searchText = searchTerm

        func items(in controller: UIViewController) -> [UIBarButtonItem] {
            let item = controller.navigationItem
            return (item.rightBarButtonItems ?? []) + item.trailingItemGroups.flatMap(\.barButtonItems)
                + (controller.toolbarItems ?? []) + controller.children.flatMap { items(in: $0) }
        }
        func items(in view: UIView) -> [UIBarButtonItem] {
            let own = (view as? UINavigationBar)?.items?.flatMap {
                ($0.rightBarButtonItems ?? []) + $0.trailingItemGroups.flatMap(\.barButtonItems)
            } ?? (view as? UIToolbar)?.items ?? []
            return own + view.subviews.flatMap { items(in: $0) }
        }
        let buttons = items(in: host) + items(in: host.view)
        let find = try XCTUnwrap(buttons.first {
            $0.accessibilityIdentifier == "findAndReplace" || $0.accessibilityLabel == String(localized: "検索・置換")
        } ?? buttons.first)
        let action = try XCTUnwrap(find.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: find.target, from: find, for: nil))
        for _ in 0..<100 where editor.findInteraction?.isFindNavigatorVisible != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        let interaction = try XCTUnwrap(editor.findInteraction)
        let session = try XCTUnwrap(interaction.activeFindSession)
        defer { interaction.dismissFindNavigator() }
        for _ in 0..<100 where session.resultCount != 40 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(session.resultCount, 40)
        func controls(in view: UIView) -> [UIControl] {
            (view as? UIControl).map { [$0] } ?? view.subviews.flatMap { controls(in: $0) }
        }
        func resultCounter(in view: UIView) -> UILabel? {
            if let label = view as? UILabel, label.accessibilityIdentifier == "findResultCount" { return label }
            return view.subviews.lazy.compactMap { resultCounter(in: $0) }.first
        }
        for _ in 0..<100 where resultCounter(in: host.view) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let counter = try XCTUnwrap(resultCounter(in: host.view))
        for _ in 0..<100 where counter.text == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(counter.text)
        XCTAssertGreaterThan(counter.bounds.width, 0)
        func visibleFrame(of child: UIView) -> CGRect {
            var frame = child.convert(child.bounds, to: window)
            var ancestor = child.superview
            while let view = ancestor {
                if view.clipsToBounds || view.layer.masksToBounds {
                    frame = frame.intersection(view.convert(view.bounds, to: window))
                }
                ancestor = view.superview
            }
            return frame
        }
        func assertCounterLayout() {
            let frame = counter.convert(counter.bounds, to: window)
            XCTAssertTrue(window.bounds.contains(frame), "The counter must stay on screen")
            XCTAssertTrue(visibleFrame(of: counter).contains(frame.insetBy(dx: 0.5, dy: 0.5)),
                          "The counter must not be clipped")
            XCTAssertLessThanOrEqual(visibleFrame(of: editor).maxY, frame.minY + 1,
                                     "The find counter must have space outside the text editor")
        }
        assertCounterLayout()
        for direction in 0..<2 {
            for step in 0..<45 {
                let identifier = direction == 0 ? "find.nextButton" : "find.previousButton"
                let button = try XCTUnwrap(scene.windows.flatMap { controls(in: $0) }.first {
                    $0.accessibilityIdentifier == identifier
                })
                let previous = session.highlightedResultIndex
                button.sendActions(for: .touchUpInside)
                try await Task.sleep(for: .milliseconds(80))
                let expected = previous == NSNotFound ? (direction == 0 ? 0 : 39)
                    : (previous + (direction == 0 ? 1 : 39)) % 40
                let summary = "\(expected + 1) / 40"
                for _ in 0..<30 where counter.text != summary {
                    try await Task.sleep(for: .milliseconds(10))
                }
                XCTAssertEqual(session.highlightedResultIndex, expected, "Navigation \(step), direction \(direction)")
                XCTAssertEqual(counter.text, summary, "Navigation \(step), direction \(direction)")
                XCTAssertFalse(counter.isHidden)
                XCTAssertNotNil(counter.window)
                XCTAssertEqual(session.resultCount, 40)
                assertCounterLayout()
            }
        }
        XCTAssertEqual(model.document.text, original)
        XCTAssertGreaterThanOrEqual(counter.bounds.width, counter.intrinsicContentSize.width)
        let query = try XCTUnwrap(scene.windows.flatMap { controls(in: $0) }.first {
            $0.accessibilityIdentifier == "find.searchField"
        } as? UITextField)
        query.selectAll(nil)
        query.insertText("該当しない検索語")
        for _ in 0..<100 where counter.text != "0" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.resultCount, 0)
        XCTAssertEqual(counter.text, "0")
        query.selectAll(nil)
        query.insertText(searchTerm)
        for _ in 0..<100 where session.resultCount != 40 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.resultCount, 40)
        interaction.dismissFindNavigator()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(counter.window, "Closing find must remove the count view and its refresh task")
        editor.becomeFirstResponder()
        let selection = editor.selectedRange
        model.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(editor.selectedRange, selection, "Closing find must not restore a stale pre-search selection")
        editor.insertText("追記")
        try await Task.sleep(for: .milliseconds(50))
        let edited = (original as NSString).replacingCharacters(in: selection, with: "追記")
        XCTAssertEqual(model.document.text, edited)
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
            XCTAssertTrue(current === editor, "Resizing should preserve the editor's input session")
            XCTAssertEqual(current.selectedRange, selection)
            XCTAssertEqual(model.document.text, edited)
            XCTAssertEqual(try MarkdownDocument(data: model.document.encodedData()).text, edited)
        }
    }

    /// Records every intermediate scroll value, including the ones a later layout pass corrects.
    @MainActor
    private final class ScrollRecorder: NSObject {
        private(set) var offsets: [CGFloat] = []
        private(set) var heights: [CGFloat] = []
        private var editor: UITextView?

        init(_ editor: UITextView) {
            self.editor = editor
            super.init()
            editor.addObserver(self, forKeyPath: "contentOffset", options: [.new], context: nil)
            editor.addObserver(self, forKeyPath: "contentSize", options: [.new], context: nil)
        }

        nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                               change: [NSKeyValueChangeKey: Any]?,
                                               context: UnsafeMutableRawPointer?) {
            let offset = keyPath == "contentOffset" ? (change?[.newKey] as? NSValue)?.cgPointValue.y : nil
            let height = keyPath == "contentSize" ? (change?[.newKey] as? NSValue)?.cgSizeValue.height : nil
            MainActor.assumeIsolated {
                if let offset { offsets.append(offset) }
                if let height { heights.append(height) }
            }
        }

        func stop() {
            editor?.removeObserver(self, forKeyPath: "contentOffset")
            editor?.removeObserver(self, forKeyPath: "contentSize")
            editor = nil
        }
    }

    /// Issue #84: rebuilding the whole editor text for every keystroke reset TextKit 2's
    /// estimated heights, so long wrapped documents jumped while typing near the end.
    func testTypingNearEndOfLongWrappedDocumentKeepsScrollPositionStable() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let model = DocumentBox()
        // Each paragraph is wider than one line at 360 points, so the document wraps throughout.
        model.document.text = (1...80).map {
            "\($0). 折り返しを検証するために生成した日本語の段落です。表示幅が狭いと二行になります。"
        }.joined(separator: "\n")
        let original = model.document.text
        // Fix the editor width so the result does not depend on the Duo posture. 360 points is
        // the narrowest column the layout uses and fits inside every posture's safe area.
        let host = AppearanceHost(rootView: NavigationStack { Container(model: model).frame(width: 360) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<100 where !host.didAppear { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(host.didAppear)
        try await Task.sleep(for: .milliseconds(200))
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        XCTAssertEqual(editor.bounds.width, 360, accuracy: 1)
        XCTAssertTrue(host.view.bounds.inset(by: host.view.safeAreaInsets)
            .contains(editor.convert(editor.bounds, to: host.view)), "The editor must stay inside the safe area")
        editor.becomeFirstResponder()
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        // Let the keyboard and the scroll to the caret settle before recording.
        var settled = editor.contentOffset.y
        var stableReadings = 0
        for _ in 0..<60 where stableReadings < 3 {
            editor.scrollRangeToVisible(editor.selectedRange)
            try await Task.sleep(for: .milliseconds(100))
            stableReadings = editor.contentOffset.y == settled ? stableReadings + 1 : 0
            settled = editor.contentOffset.y
        }
        let lineHeight = (editor.font ?? .preferredFont(forTextStyle: .body)).lineHeight
        let baseline = editor.contentOffset.y
        XCTAssertGreaterThan(editor.contentSize.height, editor.bounds.height * 2,
                             "The document must be long enough to scroll")
        XCTAssertGreaterThan(baseline, lineHeight * 10, "The caret must be near the end of a scrolled document")
        // The editor stays above the keyboard and shows the caret at the end of the document.
        host.view.layoutIfNeeded()
        let keyboardTop = host.view.keyboardLayoutGuide.layoutFrame.minY
        let editorFrame = editor.convert(editor.bounds, to: host.view)
        let caret = editor.convert(editor.caretRect(for: editor.endOfDocument), to: host.view)
        XCTAssertLessThanOrEqual(editorFrame.maxY, keyboardTop + 1, "The editor must respect the keyboard safe area")
        // UIKit may leave the caret a fraction of a point past the edge after scrolling.
        XCTAssertTrue(editorFrame.insetBy(dx: 0, dy: -2).contains(caret), "The caret must be visible: \(caret)")
        let recorder = ScrollRecorder(editor)
        defer { recorder.stop() }

        let typed = "追記した文字列を確認"
        for character in typed {
            editor.insertText(String(character))
            try await Task.sleep(for: .milliseconds(60))
        }
        for marked in ["n", "に", "にh", "にほ", "にほn", "にほん", "にほんg", "にほんご"] {
            editor.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0))
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertNotNil(editor.markedTextRange, "Updating the view must not end the composition of \(marked)")
        }
        editor.unmarkText()
        for _ in 0..<50 where model.document.text != original + typed + "にほんご" {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.document.text, original + typed + "にほんご")
        XCTAssertTrue(editor.text.hasSuffix(typed + "にほんご"))
        recorder.stop()

        // Typing at the end may scroll down by a few new lines. It must never jump back.
        let lowest = recorder.offsets.min() ?? baseline
        let highest = recorder.offsets.max() ?? baseline
        XCTAssertGreaterThanOrEqual(lowest, baseline - lineHeight,
            "contentOffset.y jumped from \(baseline) to \(lowest): \(recorder.offsets)")
        XCTAssertLessThanOrEqual(highest, baseline + lineHeight * 4,
            "contentOffset.y jumped from \(baseline) to \(highest): \(recorder.offsets)")
        let shortest = recorder.heights.min() ?? editor.contentSize.height
        XCTAssertGreaterThanOrEqual(shortest, editor.contentSize.height - lineHeight * 4,
            "contentSize.height shrank to \(shortest): \(recorder.heights)")
        print("Issue84 keyboardTop=\(keyboardTop) editorFrame=\(editorFrame) baseline=\(baseline) offsets=\(recorder.offsets) heights=\(recorder.heights)")
    }

    private final class EditorBox: ObservableObject {
        @Published var text = "0123456789"
        @Published var focused = false
        @Published var findShown = false
        @Published var showsEditor = true
        @Published var dynamicTypeSize = DynamicTypeSize.large
        let selection = MobileTextSelection()
    }

    private struct EditorContainer: View {
        @ObservedObject var model: EditorBox
        var body: some View {
            VStack {
                if model.showsEditor {
                    MobileMarkdownTextView(text: $model.text, selection: model.selection,
                        isFocused: $model.focused, isFindNavigatorPresented: $model.findShown)
                } else {
                    Text(model.text)
                }
            }
            .environment(\.dynamicTypeSize, model.dynamicTypeSize)
        }
    }

    private func showEditor(_ model: EditorBox) async throws -> (UIWindow, UIHostingController<EditorContainer>) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: EditorContainer(model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        for _ in 0..<100 where textViews(in: host.view).first?.window == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        return (window, host)
    }

    func testEditorBridgesFocusSelectionAndOutsideTextChanges() async throws {
        let model = EditorBox()
        let (window, host) = try await showEditor(model)
        defer { window.isHidden = true }
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        XCTAssertEqual(editor.accessibilityIdentifier, "markdownEditor")
        XCTAssertEqual(editor.accessibilityLabel, String(localized: "Markdown本文"))
        XCTAssertTrue(editor.isFindInteractionEnabled)

        XCTAssertTrue(editor.becomeFirstResponder())
        for _ in 0..<50 where !model.focused { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.focused, "Tapping the editor must publish focus")
        // Let SwiftUI render the published focus before the next, separate request.
        try await Task.sleep(for: .milliseconds(100))
        model.focused = false
        for _ in 0..<50 where editor.isFirstResponder { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(editor.isFirstResponder, "Clearing focus, as Settings does, must hide the keyboard")
        model.focused = true
        for _ in 0..<50 where !editor.isFirstResponder { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(editor.isFirstResponder)

        editor.selectedRange = NSRange(location: 3, length: 2)
        model.showsEditor = false
        for _ in 0..<50 where !textViews(in: host.view).isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(editor.window)
        model.showsEditor = true
        for _ in 0..<50 where textViews(in: host.view).first?.window == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let restored = try XCTUnwrap(textViews(in: host.view).first)
        XCTAssertFalse(restored === editor)
        XCTAssertEqual(restored.selectedRange, NSRange(location: 3, length: 2),
                       "Returning from the preview must keep the selection")

        model.text = "短い"
        for _ in 0..<50 where restored.text != "短い" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(restored.text, "短い")
        XCTAssertLessThanOrEqual(NSMaxRange(restored.selectedRange), 2)

        restored.becomeFirstResponder()
        // The keyboard session discards marked text that exists before it finishes starting.
        try await Task.sleep(for: .milliseconds(500))
        restored.selectedRange = NSRange(location: 2, length: 0)
        restored.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0))
        model.objectWillChange.send()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(restored.markedTextRange, "Re-rendering must not end IME composition")
        XCTAssertEqual(restored.text, "短いにほ")
        XCTAssertEqual(model.text, "短い", "Composition text is not part of the document until committed")
        restored.unmarkText()
        for _ in 0..<50 where model.text != "短いにほ" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.text, "短いにほ")
    }

    /// The keyboard session discards marked text that exists before it finishes starting, and
    /// how long that takes varies, so start the composition again until it stays.
    private func beginComposition(_ marked: String, in editor: UITextView, at location: Int) async throws {
        let original = editor.text
        editor.becomeFirstResponder()
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(250))
            guard editor.markedTextRange == nil else { return }
            XCTAssertEqual(editor.text, original, "A discarded composition must not leave text behind")
            editor.selectedRange = NSRange(location: location, length: 0)
            editor.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNotNil(editor.markedTextRange, "The composition did not start")
    }

    /// The document can change elsewhere (for example a file update) while the input method is
    /// composing. Committing must not publish the editor's older text over that change.
    func testExternalTextChangeDuringCompositionSurvivesCommit() async throws {
        let model = EditorBox()
        model.text = "一行目\n二行目"
        let (window, host) = try await showEditor(model)
        defer { window.isHidden = true }
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        try await beginComposition("にほ", in: editor, at: (editor.text as NSString).length)

        model.text = "外部の変更\n一行目\n二行目"
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(editor.markedTextRange, "An outside change must not end IME composition")
        XCTAssertEqual(editor.text, "一行目\n二行目にほ")

        editor.unmarkText()
        let merged = "外部の変更\n一行目\n二行目にほ"
        for _ in 0..<50 where model.text != merged || editor.text != merged {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.text, merged, "Committing must keep the outside change and the typed text")
        XCTAssertEqual(editor.text, merged)
        XCTAssertEqual(editor.selectedRange, NSRange(location: (merged as NSString).length, length: 0),
                       "The caret stays after the committed text")
    }

    func testCancelledCompositionAppliesTheOutsideChange() async throws {
        let model = EditorBox()
        model.text = "本文"
        let (window, host) = try await showEditor(model)
        defer { window.isHidden = true }
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        try await beginComposition("にほ", in: editor, at: 2)
        model.text = "外部の本文"
        try await Task.sleep(for: .milliseconds(200))
        // Deleting the whole composition leaves the editor's own text unchanged.
        editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0))
        editor.unmarkText()
        for _ in 0..<50 where editor.text != "外部の本文" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(editor.text, "外部の本文")
        XCTAssertEqual(model.text, "外部の本文")
    }

    func testMergingTypedTextWithAnOutsideChange() {
        func merge(_ base: String, typed: String, outside: String) -> String? {
            MobileMarkdownTextView.merging(typed: typed, outside: outside, base: base)?.text
        }
        XCTAssertEqual(merge("AB\nCD", typed: "AB\nCDにほ", outside: "X\nAB\nCD"), "X\nAB\nCDにほ")
        XCTAssertEqual(merge("AB\nCD", typed: "にほAB\nCD", outside: "AB\nCD\n追記"), "にほAB\nCD\n追記")
        XCTAssertEqual(merge("日本語🙂の文", typed: "日本語🙂のよい文", outside: "新・日本語🙂の文"), "新・日本語🙂のよい文")
        XCTAssertEqual(merge("ABCD", typed: "AD", outside: "ABCD!"), "AD!")
        XCTAssertEqual(merge("", typed: "あ", outside: "外部"), "あ外部")
        // Both sides changed the same place: there is no safe automatic result.
        XCTAssertNil(merge("ABCD", typed: "AXCD", outside: "AYCD"))
        XCTAssertNil(merge("ABCD", typed: "ABXCD", outside: "AD"))
        let shifted = MobileMarkdownTextView.merging(typed: "ABにほ", outside: "追加AB", base: "AB")
        XCTAssertEqual(shifted?.offsetAfterTypedText, 2, "Text inserted before the typed text moves the caret")
    }

    func testEditorUsesMonospacedBodyFontThatFollowsDynamicType() async throws {
        let model = EditorBox()
        let (window, host) = try await showEditor(model)
        defer { window.isHidden = true }
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        for size in [DynamicTypeSize.large, .accessibility3, .xSmall] {
            model.dynamicTypeSize = size
            let expected = UIFont.preferredFont(forTextStyle: .body,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size))).pointSize
            for _ in 0..<50 where editor.font?.pointSize != expected { try await Task.sleep(for: .milliseconds(20)) }
            let font = try XCTUnwrap(editor.font)
            XCTAssertEqual(font.pointSize, expected, "\(size)")
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace), "\(size)")
            XCTAssertTrue(textViews(in: host.view).first === editor, "Changing the text size must keep the editor")
        }
    }

    func testClosingSystemFindNavigatorResetsPresentationState() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let model = SearchBox()
        model.state = MobileEditorState(presentation: .editor)
        let host = AppearanceHost(rootView: NavigationStack { SearchContainer(model: model) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for _ in 0..<100 where !host.didAppear { try await Task.sleep(for: .milliseconds(20)) }
        let editor = try XCTUnwrap(textViews(in: host.view).first)
        for cycle in 0..<2 {
            model.state.showFindNavigator()
            for _ in 0..<100 where editor.findInteraction?.isFindNavigatorVisible != true {
                try await Task.sleep(for: .milliseconds(20))
            }
            let interaction = try XCTUnwrap(editor.findInteraction)
            XCTAssertTrue(interaction.isFindNavigatorVisible, "Cycle \(cycle)")
            XCTAssertTrue(model.state.showsFindNavigator, "Cycle \(cycle)")
            // The same call the system find bar's close button makes.
            interaction.dismissFindNavigator()
            for _ in 0..<100 where model.state.showsFindNavigator { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(model.state.showsFindNavigator, "Closing the find bar must update the state, cycle \(cycle)")
            XCTAssertFalse(interaction.isFindNavigatorVisible)
            XCTAssertTrue(textViews(in: host.view).first === editor)
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
