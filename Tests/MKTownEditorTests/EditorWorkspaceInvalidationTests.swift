import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
private final class EvaluationCounter {
    var parent = 0
    var reader = 0
    var lastLocation = -1
}

/// `EditorWorkspace` と同じく、エディタモデル本体を監視する親ビュー。
private struct ObservingParent: View {
    @ObservedObject var model: MarkdownEditorModel
    let counter: EvaluationCounter

    var body: some View {
        counter.parent += 1
        return VStack {
            Text(model.hasActiveEditor ? "active" : "inactive")
            EditorSelectionReader(selection: model.selectionState) { selection in
                let _ = counter.reader += 1
                let _ = counter.lastLocation = selection.location
                Text("\(selection.location)")
            }
        }
    }
}

@MainActor
final class EditorWorkspaceInvalidationTests: XCTestCase {
    func testSelectionChangesPublishOnlyTheSelectionState() async throws {
        let model = MarkdownEditorModel()
        let view = NSTextView()
        view.string = "abcdef"
        model.connect(view)
        try await Task.sleep(for: .milliseconds(20))
        var modelUpdates = 0
        var selectionUpdates = 0
        let modelObservation = model.objectWillChange.sink { modelUpdates += 1 }
        let selectionObservation = model.selectionState.objectWillChange.sink { selectionUpdates += 1 }

        model.selectionDidChange(NSRange(location: 3, length: 2))
        XCTAssertEqual(model.selectionState.selectedRange, NSRange(location: 3, length: 2))
        XCTAssertTrue(model.selectionState.hasSelection)
        XCTAssertEqual(model.selectedRange, NSRange(location: 3, length: 2))
        XCTAssertEqual(modelUpdates, 0, "Cursor movement must not invalidate views observing the model")
        XCTAssertGreaterThan(selectionUpdates, 0)

        model.disconnect(view)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(modelUpdates, 1, "Connection changes are still published by the model")
        withExtendedLifetime((modelObservation, selectionObservation)) {}
    }

    func testSelectionReaderUpdatesWithoutReevaluatingTheObservingParent() async throws {
        let model = MarkdownEditorModel()
        let textView = NSTextView()
        textView.string = "abcdef"
        model.connect(textView)
        let counter = EvaluationCounter()
        let host = NSHostingView(rootView: ObservingParent(model: model, counter: counter))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        let parentEvaluations = counter.parent
        let readerEvaluations = counter.reader

        for location in 1...4 {
            model.selectionDidChange(NSRange(location: location, length: 0))
            try await Task.sleep(for: .milliseconds(20))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(counter.lastLocation, 4)
        XCTAssertGreaterThan(counter.reader, readerEvaluations)
        XCTAssertEqual(counter.parent, parentEvaluations)
    }
}
