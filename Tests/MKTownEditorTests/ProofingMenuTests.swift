import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

@MainActor
final class ProofingMenuTests: XCTestCase {
    func testNativeEditMenuActionsSaveAndReflectProofingOptions() throws {
        let suite = "ProofingMenuTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        let view = EditorTextView()
        view.isEditable = true
        let coordinator = connect(view, to: settings)
        let options: [(Selector, KeyPath<EditorProofingSettings, Bool>)] = [
            (#selector(NSTextView.toggleContinuousSpellChecking(_:)), \.checksSpelling),
            (#selector(NSTextView.toggleGrammarChecking(_:)), \.checksGrammar),
            (#selector(NSTextView.toggleAutomaticSpellingCorrection(_:)), \.correctsSpelling),
            (#selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)), \.usesSmartQuotes),
            (#selector(NSTextView.toggleAutomaticDashSubstitution(_:)), \.usesSmartDashes),
            (#selector(NSTextView.toggleAutomaticTextReplacement(_:)), \.usesTextReplacement),
            (#selector(NSTextView.toggleSmartInsertDelete(_:)), \.usesSmartInsertDelete)
        ]

        for (action, option) in options {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            let original = settings.proofing[keyPath: option]
            XCTAssertTrue(view.validateMenuItem(item))
            XCTAssertEqual(item.state, original ? .on : .off)
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: view, from: item))
            XCTAssertEqual(settings.proofing[keyPath: option], !original)
            XCTAssertEqual(coordinator.proofing[keyPath: option], !original)
            XCTAssertTrue(view.validateMenuItem(item))
            XCTAssertEqual(item.state, original ? .off : .on)
        }

        let reopened = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        XCTAssertEqual(reopened.proofing, settings.proofing)
    }

    func testMenuShowsStoredSettingWhileCaretIsInCodeAndDisablesActionInReadOnlyView() throws {
        let suite = "ProofingMenuTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EditorSettingsStore(defaults: defaults, prunesMissingDocuments: false)
        let view = EditorTextView()
        view.isEditable = true
        view.string = "Use `code` here."
        view.setSelectedRange(NSRange(location: 6, length: 0))
        let coordinator = connect(view, to: settings)

        settings.proofing.usesSmartQuotes = true
        coordinator.proofing = settings.proofing
        coordinator.applyProofing()
        XCTAssertFalse(view.isAutomaticQuoteSubstitutionEnabled)
        let action = #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        XCTAssertTrue(view.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)

        view.isEditable = false
        XCTAssertFalse(view.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: view, from: item))
        XCTAssertTrue(settings.proofing.usesSmartQuotes)
    }

    private func connect(_ view: EditorTextView, to settings: EditorSettingsStore) -> MarkdownTextEditor.Coordinator {
        let model = MarkdownEditorModel()
        let coordinator = MarkdownTextEditor.Coordinator(text: .constant(view.string), model: model)
        coordinator.textView = view
        coordinator.proofingSettingsStore = settings
        coordinator.proofing = settings.proofing
        view.delegate = coordinator
        coordinator.applyProofing()
        return coordinator
    }
}
