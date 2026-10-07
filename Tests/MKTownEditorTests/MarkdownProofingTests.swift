import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class MarkdownProofingTests: XCTestCase {
    // Extended Markdown treats this as front matter; Basic parses indented code.
    private let source = "---\n    coode\n---\n\nnormal prose"

    func testSameSourceDialectSwitchUpdatesSharedProofingInBothDirections() {
        let view = NSTextView()
        view.string = source
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "coode").location,
                                      length: 0))
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(source), model: model)
        coordinator.textView = view
        coordinator.usesSharedAnalysis = true
        for dialect in [MarkdownDialect.basic, .extended, .basic, .extended] {
            model.markdownDialect = dialect
            coordinator.sharedSnapshot = DocumentSnapshot(source: source, dialect: dialect)
            coordinator.applyProofing()
            XCTAssertEqual(view.isContinuousSpellCheckingEnabled, dialect == .extended)
            XCTAssertEqual(view.isAutomaticSpellingCorrectionEnabled, dialect == .extended)
            XCTAssertEqual(view.string, source)
        }
    }

    func testPendingDialectAnalysisSuppressesCorrectionAndRejectsOldSnapshots() {
        let view = NSTextView()
        view.string = source
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "normal").location,
                                      length: 0))
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(source), model: model)
        coordinator.textView = view
        coordinator.usesSharedAnalysis = true
        for dialect in [MarkdownDialect.extended, .basic, .extended] {
            model.markdownDialect = dialect
            // The old snapshot remains published while background analysis runs.
            coordinator.applyProofing()
            XCTAssertFalse(view.isContinuousSpellCheckingEnabled)
            XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
            coordinator.sharedSnapshot = nil
            coordinator.applyProofing()
            XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled)
            coordinator.sharedSnapshot = DocumentSnapshot(source: source,
                dialect: dialect == .basic ? .extended : .basic)
            coordinator.applyProofing()
            XCTAssertFalse(view.isAutomaticSpellingCorrectionEnabled,
                           "A late result for the previous dialect must not enable correction")
            coordinator.sharedSnapshot = DocumentSnapshot(source: source, dialect: dialect)
            coordinator.applyProofing()
            XCTAssertTrue(view.isContinuousSpellCheckingEnabled)
            XCTAssertTrue(view.isAutomaticSpellingCorrectionEnabled)
        }
    }

    func testSameSourceDialectSwitchUpdatesProofingWithoutSharedAnalysis() {
        let view = NSTextView()
        view.string = source
        view.setSelectedRange(NSRange(location: (source as NSString).range(of: "coode").location,
                                      length: 0))
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(source), model: model)
        coordinator.textView = view
        for dialect in [MarkdownDialect.basic, .extended, .basic] {
            model.markdownDialect = dialect
            coordinator.applyProofing()
            XCTAssertEqual(view.isContinuousSpellCheckingEnabled, dialect == .extended)
            XCTAssertEqual(view.isAutomaticSpellingCorrectionEnabled, dialect == .extended)
        }
    }
}
