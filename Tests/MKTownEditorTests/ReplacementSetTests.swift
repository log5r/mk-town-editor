import Foundation
import XCTest
@testable import MKTownEditor

final class ReplacementSetTests: XCTestCase {
    func testAppliesEnabledRulesInOrderWithCaptureReferencesAndLiteralReplacement() throws {
        let source = "name: ALICE; name: Bob; $3"
        let set = ReplacementSet(name: "Names", rules: [
            ReplacementRule(pattern: #"name: ([a-z]+)"#, replacement: "Person($1)", usesRegularExpression: true),
            ReplacementRule(pattern: "Person(ALICE)", replacement: "Person(First)", caseSensitive: true),
            ReplacementRule(pattern: "Bob", replacement: "Other", isEnabled: false),
            ReplacementRule(pattern: "$3", replacement: "$99")
        ])

        let plan = try set.plan(in: source)
        XCTAssertEqual(plan.matchCount, 4)
        XCTAssertEqual(plan.result, "Person(First); Person(Bob); $99")
        XCTAssertEqual(try XCTUnwrap(plan.edit).applying(to: source), plan.result)
        XCTAssertTrue(plan.diff.contains("- name: ALICE\n+ Person(ALICE)\n"))
        XCTAssertTrue(plan.diff.contains("- Person(ALICE)\n+ Person(First)\n"))

        var reordered = set
        reordered.rules.swapAt(0, 1)
        XCTAssertNotEqual(try reordered.plan(in: source).result, plan.result)
    }

    func testSelectionFollowsLengthChangesAndLaterRulesCannotEditOutsideIt() throws {
        let source = "🔵 A / A / A"
        let selection = (source as NSString).range(of: "A / A")
        let set = ReplacementSet(name: "Selection", rules: [
            ReplacementRule(pattern: "A", replacement: "名前🙂"),
            ReplacementRule(pattern: "名前🙂", replacement: "B"),
            ReplacementRule(pattern: "B / A", replacement: "overflow")
        ])

        let plan = try set.plan(in: source, selection: selection)
        XCTAssertEqual(plan.matchCount, 4)
        XCTAssertEqual(plan.result, "🔵 B / B / A")
        XCTAssertEqual(try XCTUnwrap(plan.edit).range, selection)
        XCTAssertEqual(try set.highlights(in: source, selection: selection), [
            NSRange(location: selection.location, length: 1),
            NSRange(location: NSMaxRange(selection) - 1, length: 1)
        ])
    }

    func testReportsEnabledInvalidRegexWithItsRuleNumberAndIgnoresDisabledRules() throws {
        let set = ReplacementSet(name: "Validation", rules: [
            ReplacementRule(pattern: "(", usesRegularExpression: true, isEnabled: false),
            ReplacementRule(pattern: "x", replacement: "y"),
            ReplacementRule(pattern: "[", usesRegularExpression: true)
        ])

        for operation: () throws -> Void in [
            { _ = try set.plan(in: "x") }, { _ = try set.highlights(in: "x") }
        ] {
            XCTAssertThrowsError(try operation()) { error in
                guard case .rule(3, .invalidPattern) = error as? ReplacementSetError else {
                    return XCTFail("Unexpected error \(error)")
                }
            }
        }
        let blank = ReplacementSet(name: "Validation", rules: [ReplacementRule()])
        XCTAssertThrowsError(try blank.plan(in: "hello")) { error in
            XCTAssertEqual(error as? ReplacementSetError, .rule(1, .emptyPattern))
        }
        let capture = ReplacementSet(name: "Validation", rules: [
            ReplacementRule(pattern: "(x)", replacement: "$2", usesRegularExpression: true)
        ])
        XCTAssertThrowsError(try capture.plan(in: "x")) { error in
            XCTAssertEqual(error as? ReplacementSetError, .rule(1, .invalidCapture(2)))
        }
    }

    func testExcludesFencedIndentedAndInlineCodeAndRejectsOverlappingMatches() throws {
        let source = """
        word `word` word

        ```text
        word `
        ```

            word

        > ~~~
        > word
        > ~~~

        `word` and word
        """
        let set = ReplacementSet(name: "Prose", rules: [
            ReplacementRule(pattern: "word.*word", replacement: "overlap", usesRegularExpression: true),
            ReplacementRule(pattern: "word", replacement: "prose")
        ])

        let plan = try set.plan(in: source, excludesCode: true)
        XCTAssertEqual(plan.matchCount, 3)
        XCTAssertEqual(plan.result, source
            .replacingOccurrences(of: "word `word` word", with: "prose `word` prose")
            .replacingOccurrences(of: "`word` and word", with: "`word` and prose"))
        XCTAssertEqual(try set.highlights(in: source, excludesCode: true).count, 3)
    }

    func testInlineMatchingDoesNotPairBackticksAcrossBlocks() throws {
        let source = "`word\n\nword`"
        let set = ReplacementSet(name: "Prose", rules: [ReplacementRule(pattern: "word", replacement: "prose")])
        XCTAssertEqual(try set.plan(in: source, excludesCode: true).result, "`prose\n\nprose`")
    }

    func testLaterRulesRespectCodeCreatedByEarlierOnes() throws {
        let set = ReplacementSet(name: "Code", rules: [
            ReplacementRule(pattern: "<<<", replacement: "`"),
            ReplacementRule(pattern: "word", replacement: "prose")
        ])
        XCTAssertEqual(try set.plan(in: "<<<word<<< word", excludesCode: true).result, "`word` prose")
    }

    func testZeroWidthMatchCannotAppendToAnExistingCodeBlockAtEndOfSource() throws {
        let set = ReplacementSet(name: "End", rules: [
            ReplacementRule(pattern: #"\z"#, replacement: "!", usesRegularExpression: true)
        ])
        for source in ["```\nword", "```\nword\n", "```\nword\n```", "    word"] {
            XCTAssertEqual(try set.plan(in: source, excludesCode: true).result, source)
        }
        XCTAssertEqual(try set.plan(in: "```\nword\n```\n", excludesCode: true).result, "```\nword\n```\n!")
        XCTAssertEqual(try set.plan(in: "`word`", excludesCode: true).result, "`word`!")
    }

    func testHighlightsUnionOverlappingOriginalMatchesAndOmitZeroWidthMatches() throws {
        let source = "abcde"
        let set = ReplacementSet(name: "Highlights", rules: [
            ReplacementRule(pattern: "abc", replacement: "changed"),
            ReplacementRule(pattern: "cde", replacement: "after"),
            ReplacementRule(pattern: "after", replacement: "final"),
            ReplacementRule(pattern: "$", replacement: "!", usesRegularExpression: true)
        ])

        XCTAssertEqual(try set.highlights(in: source), [NSRange(location: 0, length: 5)])
        let plan = try set.plan(in: source)
        XCTAssertEqual(plan.matchCount, 2)
        XCTAssertEqual(plan.result, "changedde!")
    }

    func testPlanCanInsertIntoAnEmptySelectionCreatedByAnEarlierRule() throws {
        let source = "before REMOVE after"
        let set = ReplacementSet(name: "Insertion", rules: [
            ReplacementRule(pattern: "REMOVE"),
            ReplacementRule(pattern: "$", replacement: "one\r\ntwo", usesRegularExpression: true)
        ])
        let plan = try set.plan(in: source, selection: (source as NSString).range(of: "REMOVE"))
        XCTAssertEqual(plan.matchCount, 2)
        XCTAssertEqual(plan.result, "before one\ntwo after")
    }

    func testPlanAvoidsSplittingSurrogatePairsAndRejectsInvalidScope() throws {
        let set = ReplacementSet(name: "Emoji", rules: [ReplacementRule(pattern: "😀", replacement: "😁")])
        let source = "x😀y"
        let plan = try set.plan(in: source)
        let edit = try XCTUnwrap(plan.edit)
        XCTAssertEqual(edit.range, NSRange(location: 1, length: 2))
        XCTAssertEqual(edit.replacement, "😁")
        XCTAssertEqual(edit.applying(to: source), "x😁y")
        XCTAssertThrowsError(try set.plan(in: source, selection: NSRange(location: 2, length: 1))) { error in
            XCTAssertEqual(error as? RegexSearchError, .invalidScope)
        }
    }

    func testRepeatedTextDoesNotMoveAnEditOutsideItsSelectionOrMatch() throws {
        let range = NSRange(location: 0, length: 1)
        let plain = ReplacementSet(name: "Selection", rules: [ReplacementRule(pattern: "a")])
        let regex = ReplacementSet(name: "Document", rules: [
            ReplacementRule(pattern: "^a", usesRegularExpression: true)
        ])
        XCTAssertEqual(try plain.plan(in: "aa", selection: range).edit?.range, range)
        XCTAssertEqual(try regex.plan(in: "aa").edit?.range, range)
    }

    func testDoesNotCountReplacementsThatKeepTheExactText() throws {
        let set = ReplacementSet(name: "Case", rules: [ReplacementRule(pattern: "a", replacement: "a")])
        let plan = try set.plan(in: "a A")
        XCTAssertEqual(plan.matchCount, 1)
        XCTAssertEqual(plan.edit?.range, NSRange(location: 2, length: 1))
        XCTAssertEqual(plan.result, "a a")
    }

    func testNoNetChangeProducesNoEditEvenIfRulesMatched() throws {
        let set = ReplacementSet(name: "Cancel", rules: [
            ReplacementRule(pattern: "one", replacement: "two"),
            ReplacementRule(pattern: "two", replacement: "one")
        ])
        let plan = try set.plan(in: "one")
        XCTAssertEqual(plan.matchCount, 2)
        XCTAssertNil(plan.edit)
        XCTAssertTrue(plan.diff.isEmpty)
    }

    func testJSONRoundTripKeepsOrderAndOptionsWithFreshIdentities() throws {
        let original = ReplacementSet(name: "用語統一", rules: [
            ReplacementRule(pattern: "(色)", replacement: "$1彩", usesRegularExpression: true,
                            caseSensitive: true, notes: "見出し用"),
            ReplacementRule(pattern: "削除対象", isEnabled: false)
        ])
        let imported = try ReplacementSet.fromJSON(original.jsonData())
        XCTAssertEqual(imported.name, original.name)
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertNotEqual(imported.rules.map(\.id), original.rules.map(\.id))
        var copy = imported
        copy.id = original.id
        for index in copy.rules.indices { copy.rules[index].id = original.rules[index].id }
        XCTAssertEqual(copy, original)

        XCTAssertThrowsError(try ReplacementSet.fromJSON(Data(#"{"version":2}"#.utf8))) { error in
            XCTAssertEqual(error as? ReplacementSetError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try ReplacementSet.fromJSON(Data(#"{"version":1}"#.utf8))) { error in
            XCTAssertEqual(error as? ReplacementSetError, .invalidArchive)
        }
    }

    func testReadsUTF8TSVWithBOMMixedLineEndingsAndEmptyReplacement() throws {
        let input = Data("\u{FEFF}元\t先\r\n\r\n残さない\t\r 英字 \t $1 \n".utf8)
        let set = try ReplacementSet.fromTSV(input, named: "Import")
        XCTAssertEqual(set.name, "Import")
        XCTAssertEqual(set.rules.map(\.pattern), ["元", "残さない", " 英字 "])
        XCTAssertEqual(set.rules.map(\.replacement), ["先", "", " $1 "])
        XCTAssertTrue(set.rules.allSatisfy { $0.isEnabled && !$0.usesRegularExpression })

        XCTAssertThrowsError(try ReplacementSet.fromTSV(Data("ok\tyes\ninvalid\n".utf8), named: "Invalid")) { error in
            XCTAssertEqual(error as? ReplacementSetError, .invalidTSVLine(2))
        }
        XCTAssertThrowsError(try ReplacementSet.fromTSV(Data([0xFF]), named: "Invalid")) { error in
            XCTAssertEqual(error as? ReplacementSetError, .invalidUTF8)
        }
    }
}
