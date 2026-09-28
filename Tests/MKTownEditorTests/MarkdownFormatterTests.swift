import XCTest
@testable import MKTownEditor

final class MarkdownFormatterTests: XCTestCase {
    func testBoldWrapsSelectedTextAndKeepsContentSelected() {
        let result = MarkdownFormatter.apply(.bold, to: "hello world", selection: NSRange(location: 6, length: 5))

        XCTAssertEqual(result.applying(to: "hello world"), "hello **world**")
        XCTAssertEqual(result.selection, NSRange(location: 8, length: 5))
    }

    func testBoldInsertsPlaceholderAtInsertionPoint() {
        let result = MarkdownFormatter.apply(.bold, to: "hello ", selection: NSRange(location: 6, length: 0))

        let updated = result.applying(to: "hello ")
        XCTAssertEqual(updated, "hello **太字**")
        XCTAssertEqual((updated as NSString).substring(with: result.selection), "太字")
    }

    func testLinkSelectsURLForImmediateReplacement() {
        let result = MarkdownFormatter.apply(.link, to: "Apple", selection: NSRange(location: 0, length: 5))

        let updated = result.applying(to: "Apple")
        XCTAssertEqual(updated, "[Apple](https://)")
        XCTAssertEqual((updated as NSString).substring(with: result.selection), "https://")
    }

    func testListPrefixesEverySelectedLine() {
        let source = "one\ntwo\nthree"
        let result = MarkdownFormatter.apply(.unorderedList, to: source, selection: NSRange(location: 0, length: 7))

        XCTAssertEqual(result.applying(to: source), "- one\n- two\nthree")
    }

    func testOutOfBoundsSelectionIsClamped() {
        let result = MarkdownFormatter.apply(.italic, to: "abc", selection: NSRange(location: 99, length: 10))

        XCTAssertEqual(result.applying(to: "abc"), "abc_斜体_")
    }

    func testUTF16SelectionMatchesNSTextViewForJapaneseText() {
        let source = "絵文字🙂と日本語"
        let range = (source as NSString).range(of: "🙂と")
        let result = MarkdownFormatter.apply(.inlineCode, to: source, selection: range)

        let updated = result.applying(to: source)
        XCTAssertEqual(updated, "絵文字`🙂と`日本語")
        XCTAssertEqual((updated as NSString).substring(with: result.selection), "🙂と")
    }

    func testEditChangesOnlySelectedUTF16Range() {
        let source = "前🙂後"
        let selection = (source as NSString).range(of: "🙂")
        let edit = MarkdownFormatter.apply(.bold, to: source, selection: selection)

        XCTAssertEqual(edit.range, selection)
        XCTAssertEqual(edit.replacement, "**🙂**")
        XCTAssertEqual(edit.applying(to: source), "前**🙂**後")
    }

    func testLineEditChangesOnlyAffectedLines() {
        let source = "one\ntwo\nthree"
        let edit = MarkdownFormatter.apply(.quote, to: source, selection: NSRange(location: 5, length: 0))

        XCTAssertEqual(edit.range, NSRange(location: 4, length: 4))
        XCTAssertEqual(edit.replacement, "> two\n")
        XCTAssertEqual(edit.applying(to: source), "one\n> two\nthree")
    }

    func testQuoteCanBeRemovedWithoutChangingNestedIndentOrLineEndings() {
        let source = "前\r\n  > - 親\r\n  >   - 子\r\n後"
        let selection = (source as NSString).range(of: "親\r\n  >   - 子")
        let edit = MarkdownFormatter.apply(.quote, to: source, selection: selection)
        XCTAssertEqual(edit.applying(to: source), "前\r\n  - 親\r\n    - 子\r\n後")
    }

    func testQuoteCommandQuotesOnlyUnquotedLinesInMixedSelection() {
        let source = "> 引用\n本文"
        let edit = MarkdownFormatter.apply(.quote, to: source,
            selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(edit.applying(to: source), "> 引用\n> 本文")
    }

    func testQuoteConvertsToListAndPreservesNestedItems() {
        let source = "> 親\n>   子"
        let edit = MarkdownFormatter.apply(.unorderedList, to: source,
            selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(edit.applying(to: source), "- 親\n  - 子")
    }

    func testListConvertsToQuoteAndKeepsIndentAndTaskState() {
        let source = "- 親\n  - 子\n- [x] 完了"
        let edit = MarkdownFormatter.apply(.quote, to: source,
            selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(edit.applying(to: source), "> 親\n  > 子\n> [x] 完了")
    }

    func testPlainBlockRemovesOneOuterMarkerPerLine() {
        let source = "> - 引用のリスト\n  - 親\n    - 子\n## 見出し"
        let edit = MarkdownFormatter.apply(.plainBlock, to: source,
            selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(edit.applying(to: source), "- 引用のリスト\n  親\n    子\n見出し")
    }

    func testQuoteAtEmptyDocumentCreatesMarker() {
        let edit = MarkdownFormatter.apply(.quote, to: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.applying(to: ""), "> ")
    }

    func testRemoveFormattingKeepsVisibleLabelsAndDestinations() {
        let source = "**強調🙂** [案内](https://example.com/a_b \"title\") ![図](images/a.png)"
        let edit = MarkdownFormatter.apply(.removeFormatting, to: source,
            selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(edit.applying(to: source), "強調🙂 案内 (https://example.com/a_b) 図 (images/a.png)")
    }

    func testRemoveFormattingAtCaretOnlyChangesContainingConstruct() {
        let source = "前 **強調** と *斜体*"
        let location = (source as NSString).range(of: "強調").location
        let edit = MarkdownFormatter.apply(.removeFormatting, to: source,
            selection: NSRange(location: location, length: 0))
        XCTAssertEqual(edit.applying(to: source), "前 強調 と *斜体*")
    }

    func testRemoveFormattingLeavesUnselectedMarkupIntact() {
        let source = "**前** と ~~後~~"
        let selection = (source as NSString).range(of: "~~後~~")
        let edit = MarkdownFormatter.apply(.removeFormatting, to: source, selection: selection)
        XCTAssertEqual(edit.applying(to: source), "**前** と 後")
    }

    func testRemoveFormattingKeepsFencedCodeLiteralAndRemovesNearbyEmphasis() {
        let source = "**前**\n```md\n**literal**\n```\n~~後~~"
        let edit = MarkdownFormatter.apply(.removeFormatting, to: source,
            selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(edit.applying(to: source), "前\n```md\n**literal**\n```\n後")
    }

    func testTableOfContentsUsesHeadingLevelsAndDuplicateAnchors() {
        let source = "# Guide\n## Steps\n## Steps"
        let edit = MarkdownFormatter.apply(.tableOfContents, to: source,
            selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.applying(to: source),
            "- [Guide](#guide)\n  - [Steps](#steps)\n  - [Steps](#steps-1)\n\n" + source)
        XCTAssertEqual((edit.applying(to: source) as NSString).substring(with: edit.selection),
            "- [Guide](#guide)\n  - [Steps](#steps)\n  - [Steps](#steps-1)")
    }

    func testTableOfContentsReplacesOnlySelectedExistingList() {
        let source = "# One\n\n- [old](#old)\n\n## Two"
        let selection = (source as NSString).range(of: "- [old](#old)")
        let edit = MarkdownFormatter.apply(.tableOfContents, to: source, selection: selection)
        XCTAssertEqual(edit.range, selection)
        XCTAssertEqual(edit.applying(to: source),
            "# One\n\n- [One](#one)\n  - [Two](#two)\n\n## Two")
    }

    func testTableOfContentsPreservesCRLFAndLeavesDocumentWithoutHeadingsUntouched() {
        let source = "# 日本語\r\n## 子"
        let edit = MarkdownFormatter.apply(.tableOfContents, to: source,
            selection: NSRange(location: (source as NSString).length, length: 0))
        XCTAssertEqual(edit.applying(to: source),
            source + "\r\n\r\n- [日本語](#日本語)\r\n  - [子](#子)")
        let plain = MarkdownFormatter.apply(.tableOfContents, to: "本文",
            selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(plain.applying(to: "本文"), "本文")
    }

    func testRenumberListAtCaretKeepsStartAndRenumbersOnlySiblingItems() {
        let source = "4. 親\n  7. 子\n  9. 子\n8. 次\n\n2. 別"
        let caret = (source as NSString).range(of: "親").location
        let edit = MarkdownFormatter.apply(.renumberList, to: source,
            selection: NSRange(location: caret, length: 0))
        XCTAssertEqual(edit.applying(to: source), "4. 親\n  7. 子\n  9. 子\n5. 次\n\n2. 別")
    }

    func testRenumberSelectedNestedListWithoutChangingOuterSequence() {
        let source = "4. 親\r\n  7) 子🙂\r\n  9) 次\r\n8. 親"
        let selected = (source as NSString).range(of: "子🙂\r\n  9) 次")
        let edit = MarkdownFormatter.apply(.renumberList, to: source, selection: selected)
        XCTAssertEqual(edit.applying(to: source), "4. 親\r\n  7) 子🙂\r\n  8) 次\r\n8. 親")
    }

    func testRenumberListOutsideOrderedItemIsNoOp() {
        let source = "- bullet\n本文"
        let edit = MarkdownFormatter.apply(.renumberList, to: source,
            selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(edit.applying(to: source), source)
    }

    func testDuplicateSelectedLinesPreservesCRLFAndSelectsCopy() {
        let source = "前\r\n🙂\r\n二\r\n後"
        let selection = (source as NSString).range(of: "🙂\r\n二\r\n")
        let edit = MarkdownFormatter.apply(.duplicateLines, to: source, selection: selection)
        let updated = edit.applying(to: source)
        XCTAssertEqual(updated, "前\r\n🙂\r\n二\r\n🙂\r\n二\r\n後")
        XCTAssertEqual((updated as NSString).substring(with: edit.selection), "🙂\r\n二\r\n")
    }

    func testDuplicateFinalLineWithoutNewlineAddsSeparator() {
        let source = "前\n最後"
        let edit = MarkdownFormatter.apply(.duplicateLines, to: source,
            selection: (source as NSString).range(of: "最後"))
        XCTAssertEqual(edit.applying(to: source), "前\n最後\n最後")
    }

    func testMoveLinesUpAndDownAtDocumentEnd() {
        let source = "前\n🙂\n後"
        let up = MarkdownFormatter.apply(.moveLinesUp, to: source,
            selection: (source as NSString).range(of: "後"))
        XCTAssertEqual(up.applying(to: source), "前\n後\n🙂")

        let down = MarkdownFormatter.apply(.moveLinesDown, to: source,
            selection: (source as NSString).range(of: "🙂"))
        XCTAssertEqual(down.applying(to: source), "前\n後\n🙂")
        XCTAssertEqual((down.applying(to: source) as NSString).substring(with: down.selection), "🙂")
    }

    func testDeleteFinalLineRemovesPreviousSeparatorAndExactSelectedLines() {
        let source = "前\r\n🙂"
        let last = MarkdownFormatter.apply(.deleteLines, to: source,
            selection: (source as NSString).range(of: "🙂"))
        XCTAssertEqual(last.applying(to: source), "前")

        let multi = "one\ntwo\nthree"
        let first = MarkdownFormatter.apply(.deleteLines, to: multi,
            selection: NSRange(location: 0, length: 4))
        XCTAssertEqual(first.applying(to: multi), "two\nthree")
    }

    func testCommentWrapsAndUnwrapsMultilineSelectionWithoutChangingContent() {
        let source = "前\r\n🙂\r\n後"
        let selection = (source as NSString).range(of: "🙂\r\n後")
        let wrapped = try! XCTUnwrap(MarkdownFormatter.commentEdit(in: source, selection: selection))
        let commented = wrapped.applying(to: source)
        XCTAssertEqual(commented, "前\r\n<!-- 🙂\r\n後 -->")

        let unwrapped = try! XCTUnwrap(MarkdownFormatter.commentEdit(in: commented,
            selection: (commented as NSString).range(of: "🙂")))
        XCTAssertEqual(unwrapped.applying(to: commented), source)
    }

    func testCommentAtEmptySelectionPlacesCaretInsideAndRejectsInvalidContent() {
        let edit = try! XCTUnwrap(MarkdownFormatter.commentEdit(in: "",
            selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(edit.applying(to: ""), "<!--  -->")
        XCTAssertEqual(edit.selection, NSRange(location: 5, length: 0))
        XCTAssertNil(MarkdownFormatter.commentEdit(in: "a--b",
            selection: NSRange(location: 0, length: 4)))
    }

    func testHeadingLevelReplacesExistingMarkerAndClosingHashes() {
        let source = "  ## 見出し 🙂 ##\n本文"
        let edit = MarkdownFormatter.apply(.heading(level: 4), to: source, selection: NSRange(location: 6, length: 0))

        XCTAssertEqual(edit.applying(to: source), "  #### 見出し 🙂\n本文")
        XCTAssertEqual(edit.range.location, 0)
    }

    func testHeadingCanBecomeBodyWithoutChangingOtherLines() {
        let source = "前\n### 見出し\r\n後"
        let selection = (source as NSString).range(of: "見出し")
        let edit = MarkdownFormatter.apply(.heading(level: 0), to: source, selection: selection)

        XCTAssertEqual(edit.applying(to: source), "前\n見出し\r\n後")
        XCTAssertEqual(edit.replacement, "見出し\r\n")
    }

    func testHeadingChangesEachSelectedLine() {
        let source = "# 一\n## 二\n三"
        let edit = MarkdownFormatter.apply(.heading(level: 2), to: source, selection: NSRange(location: 0, length: 8))

        XCTAssertEqual(edit.applying(to: source), "## 一\n## 二\n三")
    }

    func testHeadingOnEmptyDocumentPlacesInsertionAfterMarker() {
        let edit = MarkdownFormatter.apply(.heading(level: 3), to: "", selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.applying(to: ""), "### ")
        XCTAssertEqual(edit.selection, NSRange(location: 4, length: 0))
    }

    func testBoldToggleRemovesSurroundingMarkersForInnerAndWholeSelection() {
        let source = "前**強調🙂**後"
        for range in [(source as NSString).range(of: "強調🙂"),
                      (source as NSString).range(of: "**強調🙂**")] {
            let edit = MarkdownFormatter.apply(.bold, to: source, selection: range)
            let updated = edit.applying(to: source)

            XCTAssertEqual(updated, "前強調🙂後")
            XCTAssertEqual((updated as NSString).substring(with: edit.selection), "強調🙂")
        }
    }

    func testEmptySelectionInsideFormattedTextRemovesFormattingAndKeepsCaret() {
        let source = "**hello**"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: NSRange(location: 4, length: 0))

        XCTAssertEqual(edit.applying(to: source), "hello")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 0))
    }

    func testMixedSelectionBecomesUniformlyFormatted() {
        let source = "**one** and two"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))

        XCTAssertEqual(edit.applying(to: source), "**one and two**")
        XCTAssertEqual(edit.selection, NSRange(location: 2, length: 11))
    }

    func testFullyFormattedMixedSpansAreUnwrappedTogether() {
        let source = "**one** **two**"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))

        XCTAssertEqual(edit.applying(to: source), "one two")
    }

    func testItalicAndCodeToggleLeaveOtherFormattingInPlace() {
        let italic = MarkdownFormatter.apply(.italic, to: "_word_",
                                              selection: NSRange(location: 1, length: 4))
        let code = MarkdownFormatter.apply(.inlineCode, to: "**`word`**",
                                            selection: NSRange(location: 3, length: 4))

        XCTAssertEqual(italic.applying(to: "_word_"), "word")
        XCTAssertEqual(code.applying(to: "**`word`**"), "**word**")
    }

    func testEscapedMarkersAreNotRemoved() {
        let source = "\\**literal**"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: (source as NSString).range(of: "literal"))

        XCTAssertEqual(edit.applying(to: source), "\\****literal****")
    }

    func testLiteralBoldMarkersInsideCodeAreNotToggledAway() {
        let source = "`**literal**`"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: (source as NSString).range(of: "literal"))

        XCTAssertEqual(edit.applying(to: source), "`****literal****`")
    }

    func testCaretImmediatelyOutsideFormattingDoesNotRemoveIt() {
        let source = "**word**"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: NSRange(location: 0, length: 0))

        XCTAssertEqual(edit.applying(to: source), "**太字****word**")
    }

    func testAlternativeMarkersAndLongCodeDelimiterCanBeToggled() {
        for (style, source, word) in [
            (MarkdownFormattingStyle.bold, "__strong__", "strong"),
            (.italic, "*emphasis*", "emphasis"),
            (.inlineCode, "``a`b``", "a`b")
        ] {
            let edit = MarkdownFormatter.apply(style, to: source,
                                               selection: (source as NSString).range(of: word))
            XCTAssertEqual(edit.applying(to: source), word)
        }
    }

    func testToggleHandlesNestedAlternativeMarkersAndCodeChild() {
        let nested = "**outer __inner__**"
        let whole = MarkdownFormatter.apply(.bold, to: nested,
                                            selection: NSRange(location: 0, length: (nested as NSString).length))
        XCTAssertEqual(whole.applying(to: nested), "outer inner")

        let inner = MarkdownFormatter.apply(.bold, to: nested,
                                            selection: (nested as NSString).range(of: "inner"))
        XCTAssertEqual(inner.applying(to: nested), "**outer inner**")

        let withCode = "**one `two` three**"
        let codeChild = MarkdownFormatter.apply(.bold, to: withCode,
                                                selection: (withCode as NSString).range(of: "one `two` three"))
        XCTAssertEqual(codeChild.applying(to: withCode), "one `two` three")
    }

    func testPartialSelectionExpandsAcrossExistingFormatting() {
        let source = "**one** and two"
        let edit = MarkdownFormatter.apply(.bold, to: source,
                                           selection: (source as NSString).range(of: "one** and"))
        XCTAssertEqual(edit.applying(to: source), "**one and** two")
    }

    func testStrikethroughWrapsSelectedUnicodeAndKeepsSelection() {
        let source = "前🙂後"
        let edit = MarkdownFormatter.apply(.strikethrough, to: source,
                                           selection: (source as NSString).range(of: "🙂"))
        let updated = edit.applying(to: source)
        XCTAssertEqual(updated, "前~~🙂~~後")
        XCTAssertEqual((updated as NSString).substring(with: edit.selection), "🙂")
    }

    func testStrikethroughPlaceholderIsSelectedAtEmptySelectionAndDocumentEnd() {
        let source = "前"
        let edit = MarkdownFormatter.apply(.strikethrough, to: source,
                                           selection: NSRange(location: (source as NSString).length, length: 0))
        let updated = edit.applying(to: source)
        XCTAssertEqual(updated, "前~~取り消し線~~")
        XCTAssertEqual((updated as NSString).substring(with: edit.selection), "取り消し線")
    }

    func testStrikethroughTogglesAndNormalizesMixedSelection() {
        let source = "~~one~~ and two"
        let inner = MarkdownFormatter.apply(.strikethrough, to: source,
                                            selection: (source as NSString).range(of: "one"))
        XCTAssertEqual(inner.applying(to: source), "one and two")

        let mixed = MarkdownFormatter.apply(.strikethrough, to: source,
                                            selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(mixed.applying(to: source), "~~one and two~~")
    }

    func testStrikethroughDoesNotRemoveMarkersInsideCode() {
        let source = "`~~literal~~`"
        let edit = MarkdownFormatter.apply(.strikethrough, to: source,
                                           selection: (source as NSString).range(of: "literal"))
        XCTAssertEqual(edit.applying(to: source), "`~~~~literal~~~~`")
    }

    func testOrderedListNumbersMultipleSelectedLinesAndLeavesOtherLines() {
        let source = "前\n一\n二\n後"
        let edit = MarkdownFormatter.apply(.orderedList, to: source,
                                           selection: (source as NSString).range(of: "一\n二"))
        XCTAssertEqual(edit.applying(to: source), "前\n1. 一\n2. 二\n後")
    }

    func testOrderedListConvertsExistingBulletsAndRenumbersFromExistingStart() {
        let source = "- one\n+ two\n* three"
        let edit = MarkdownFormatter.apply(.orderedList, to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(edit.applying(to: source), "1. one\n2. two\n3. three")

        let numbered = "3) one\n8. two"
        let renumbered = MarkdownFormatter.apply(.orderedList, to: numbered,
                                                 selection: NSRange(location: 0, length: (numbered as NSString).length))
        XCTAssertEqual(renumbered.applying(to: numbered), "3. one\n4. two")
    }

    func testOrderedListPreservesIndentBlankLinesAndCRLF() {
        let source = "  - 🙂\r\n\r\n  * 次"
        let edit = MarkdownFormatter.apply(.orderedList, to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(edit.applying(to: source), "  1. 🙂\r\n\r\n  2. 次")
    }

    func testOrderedListAtEmptyDocumentAndBlankLinePlacesCaretAfterMarker() {
        for (source, location, expected) in [
            ("", 0, "1. "),
            ("前\n", 2, "前\n1. "),
            ("前\n\n後", 2, "前\n1. \n後")
        ] {
            let edit = MarkdownFormatter.apply(.orderedList, to: source,
                                               selection: NSRange(location: location, length: 0))
            XCTAssertEqual(edit.applying(to: source), expected)
            XCTAssertEqual(edit.selection, NSRange(location: location + 3, length: 0))
        }
    }

    func testTaskListConvertsMultipleBulletsAndNumberedItems() {
        let source = "- one\n2. two\nplain"
        let edit = MarkdownFormatter.apply(.taskList, to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(edit.applying(to: source), "- [ ] one\n- [ ] two\n- [ ] plain")
    }

    func testTaskAndBulletCommandsConvertInBothDirections() {
        let tasks = "- [x] done\n- [ ] todo\n- [X] upper"
        let bullets = MarkdownFormatter.apply(.unorderedList, to: tasks,
                                              selection: NSRange(location: 0, length: (tasks as NSString).length))
        XCTAssertEqual(bullets.applying(to: tasks), "- done\n- todo\n- upper")

        let unchanged = MarkdownFormatter.apply(.taskList, to: tasks,
                                                selection: NSRange(location: 0, length: (tasks as NSString).length))
        XCTAssertEqual(unchanged.applying(to: tasks), tasks)
    }

    func testOrderedListKeepsTaskStateWhenConvertingTaskItems() {
        let source = "- [x] done\n- [ ] todo"
        let edit = MarkdownFormatter.apply(.orderedList, to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(edit.applying(to: source), "1. [x] done\n2. [ ] todo")
    }

    func testTaskListKeepsBlankLinesIndentationCRLFAndUTF16Selection() {
        let source = "  - 🙂\r\n\r\n  - 次"
        let edit = MarkdownFormatter.apply(.taskList, to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))
        let updated = edit.applying(to: source)
        XCTAssertEqual(updated, "  - [ ] 🙂\r\n\r\n  - [ ] 次")
        XCTAssertEqual(edit.selection.length, (updated as NSString).length)
    }

    func testTaskListAtEmptyDocumentAndBlankLinePlacesCaretAfterMarker() {
        for (source, location, expected) in [
            ("", 0, "- [ ] "),
            ("前\n\n後", 2, "前\n- [ ] \n後")
        ] {
            let edit = MarkdownFormatter.apply(.taskList, to: source,
                                               selection: NSRange(location: location, length: 0))
            XCTAssertEqual(edit.applying(to: source), expected)
            XCTAssertEqual(edit.selection, NSRange(location: location + 6, length: 0))
        }
    }

    func testToggleTaskAtCaretChangesOnlyCurrentItem() {
        let source = "- [ ] first\n- [x] second"
        let edit = MarkdownFormatter.toggleTasks(in: source,
            selection: NSRange(location: (source as NSString).range(of: "first").location, length: 0))
        XCTAssertEqual(edit?.applying(to: source), "- [x] first\n- [x] second")
    }

    func testToggleSelectedTasksUsesOneStateForAllItems() {
        let mixed = "- [ ] first\n- [x] second\n- plain"
        let selected = NSRange(location: 0, length: (mixed as NSString).length)
        let checked = MarkdownFormatter.toggleTasks(in: mixed, selection: selected)
        XCTAssertEqual(checked?.applying(to: mixed), "- [x] first\n- [x] second\n- plain")

        let allChecked = "- [x] first\n1. [X] second"
        let unchecked = MarkdownFormatter.toggleTasks(in: allChecked,
            selection: NSRange(location: 0, length: (allChecked as NSString).length))
        XCTAssertEqual(unchecked?.applying(to: allChecked), "- [ ] first\n1. [ ] second")

        let twoUnchecked = "- [ ] first\n- [ ] second"
        let firstLine = MarkdownFormatter.toggleTasks(in: twoUnchecked,
            selection: NSRange(location: 0, length: ("- [ ] first\n" as NSString).length))
        XCTAssertEqual(firstLine?.applying(to: twoUnchecked), "- [x] first\n- [ ] second")
    }

    func testToggleTaskSupportsNestedQuoteAndSkipsCodeAndPlainText() {
        let source = "> - [ ] quoted\n\n```\n- [ ] literal\n```\n\n- plain"
        let quoted = MarkdownFormatter.toggleTasks(in: source,
            selection: NSRange(location: (source as NSString).range(of: "quoted").location, length: 0))
        XCTAssertEqual(quoted?.applying(to: source),
                       "> - [x] quoted\n\n```\n- [ ] literal\n```\n\n- plain")
        XCTAssertNil(MarkdownFormatter.toggleTasks(in: source,
            selection: NSRange(location: (source as NSString).range(of: "literal").location, length: 0)))
        XCTAssertNil(MarkdownFormatter.toggleTasks(in: source,
            selection: NSRange(location: (source as NSString).range(of: "plain").location, length: 0)))

        let previewLocation = try! XCTUnwrap(MarkdownAnalysis(source).blocks.first(where: { $0.task != nil }))
            .sourceRange.location
        XCTAssertEqual(MarkdownFormatter.toggleTasks(in: source,
            selection: NSRange(location: previewLocation, length: 0))?.applying(to: source),
            "> - [x] quoted\n\n```\n- [ ] literal\n```\n\n- plain")
    }

    func testCodeBlockInsertionAtEmptyDocumentPlacesCaretInsideFence() {
        let edit = MarkdownFormatter.apply(.codeBlock(language: nil), to: "",
                                           selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(edit.applying(to: ""), "```\n\n```")
        XCTAssertEqual(edit.selection, NSRange(location: 4, length: 0))
    }

    func testCodeBlockWrapsSelectedTextAndUsesChosenLanguage() {
        let source = "print(\"🙂\")"
        let edit = MarkdownFormatter.apply(.codeBlock(language: .swift), to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))
        let updated = edit.applying(to: source)
        XCTAssertEqual(updated, "```swift\nprint(\"🙂\")\n```")
        XCTAssertEqual((updated as NSString).substring(with: edit.selection), source)
    }

    func testCodeBlockFenceExceedsEveryBacktickRunInSelection() {
        let source = "before ``` middle ```` after"
        let edit = MarkdownFormatter.apply(.codeBlock(language: .markdown), to: source,
                                           selection: NSRange(location: 0, length: (source as NSString).length))
        let updated = edit.applying(to: source)
        XCTAssertEqual(updated, "`````markdown\n\(source)\n`````")
        let code = MarkdownAnalysis(updated).rootBlocks.first
        XCTAssertEqual(code?.kind, .codeBlock)
        XCTAssertEqual(code?.content, source)
        XCTAssertEqual(code?.codeLanguage, "markdown")
    }

    func testCodeBlockCreatesLineBoundariesAroundPartialLineSelection() {
        let source = "preCODEpost"
        let edit = MarkdownFormatter.apply(.codeBlock(language: .python), to: source,
                                           selection: (source as NSString).range(of: "CODE"))
        let updated = edit.applying(to: source)
        XCTAssertEqual(updated, "pre\n```python\nCODE\n```\npost")
        XCTAssertEqual((updated as NSString).substring(with: edit.selection), "CODE")
    }

    func testCodeBlockPreservesCRLFAndAvoidsExtraContentLine() {
        let source = "pre\r\n🙂\r\npost"
        let edit = MarkdownFormatter.apply(.codeBlock(language: .json), to: source,
                                           selection: (source as NSString).range(of: "🙂"))
        XCTAssertEqual(edit.applying(to: source), "pre\r\n```json\r\n🙂\r\n```\r\npost")

        let multiline = "one\n"
        let full = MarkdownFormatter.apply(.codeBlock(language: nil), to: multiline,
                                           selection: NSRange(location: 0, length: (multiline as NSString).length))
        XCTAssertEqual(full.applying(to: multiline), "```\none\n```")
    }

    func testHorizontalRuleSeparatesAdjacentParagraphs() {
        let source = "前の段落\n次の段落"
        let location = (source as NSString).range(of: "次の段落").location
        let edit = MarkdownFormatter.apply(.horizontalRule, to: source,
                                           selection: NSRange(location: location, length: 0))
        let updated = edit.applying(to: source)
        XCTAssertEqual(updated, "前の段落\n\n***\n\n次の段落")
        XCTAssertEqual(MarkdownAnalysis(updated).rootBlocks.map(\.kind),
                       [.paragraph, .blank, .horizontalRule, .blank, .paragraph])
    }

    func testHorizontalRuleInMiddleOfLinePreservesBothSides() {
        let source = "beforeafter"
        let edit = MarkdownFormatter.apply(.horizontalRule, to: source,
                                           selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(edit.applying(to: source), "before\n\n***\n\nafter")
        XCTAssertEqual(edit.selection, NSRange(location: 13, length: 0))
    }

    func testHorizontalRuleAtDocumentStartCannotBecomeFrontMatterOrSetext() {
        for source in ["", "heading"] {
            let edit = MarkdownFormatter.apply(.horizontalRule, to: source,
                                               selection: NSRange(location: 0, length: 0))
            let updated = edit.applying(to: source)
            XCTAssertTrue(updated.hasPrefix("***"))
            XCTAssertEqual(MarkdownAnalysis(updated).rootBlocks.first?.kind, .horizontalRule)
        }
    }

    func testHorizontalRulePreservesExistingBlankLinesAndCRLF() {
        let source = "one\r\n\r\ntwo"
        let location = (source as NSString).range(of: "two").location
        let edit = MarkdownFormatter.apply(.horizontalRule, to: source,
                                           selection: NSRange(location: location, length: 0))
        XCTAssertEqual(edit.applying(to: source), "one\r\n\r\n***\r\n\r\ntwo")
    }

    func testHorizontalRuleReplacesSelectedTextWithoutChangingSurroundingParagraphs() {
        let source = "one\nreplace\ntwo"
        let edit = MarkdownFormatter.apply(.horizontalRule, to: source,
                                           selection: (source as NSString).range(of: "replace"))
        XCTAssertEqual(edit.applying(to: source), "one\n\n***\n\ntwo")
    }

    func testAutoFormatPreservesFrontMatterCodeAndHardBreaksAndIsIdempotent() throws {
        let source = "---\ntitle: keep  \n---\n#  Title \n+ item\nline  \n```md\n+ code  \n```\n"
        let plan = try XCTUnwrap(MarkdownAutoFormat.plan(source))
        let updated = plan.edit.applying(to: source)
        XCTAssertEqual(updated,
            "---\ntitle: keep  \n---\n# Title\n- item\nline  \n```md\n+ code  \n```\n")
        XCTAssertEqual(plan.changes.map(\.line), [4, 5])
        XCTAssertNil(MarkdownAutoFormat.plan(updated))
    }

    func testAutoFormatSelectionChangesOnlySelectedLinesAndKeepsCRLF() throws {
        let source = "#  One\r\n+ first\r\n* second\r\n"
        let selection = (source as NSString).range(of: "+ first")
        let plan = try XCTUnwrap(MarkdownAutoFormat.plan(source, selection: selection))
        XCTAssertEqual(plan.edit.applying(to: source), "#  One\r\n- first\r\n* second\r\n")
        XCTAssertEqual(plan.changes.map(\.line), [2])
        XCTAssertNil(MarkdownAutoFormat.plan(source,
            selection: NSRange(location: NSNotFound, length: 1)))
    }

    func testFootnoteInsertionUsesUniqueIDAndPreservesCRLF() throws {
        let source = "Text[^fn1] and [^FN2].\r\n"
        let selection = (source as NSString).range(of: "Text")
        let edit = try XCTUnwrap(MarkdownFootnoteInsertion.plan(in: source, selection: selection))
        let updated = edit.applying(to: source)
        XCTAssertEqual(updated, "Text[^fn3][^fn1] and [^FN2].\r\n\r\n[^fn3]: ")
        XCTAssertEqual(edit.selection.location, (updated as NSString).length)
        XCTAssertNil(MarkdownFootnoteInsertion.plan(in: source,
            selection: NSRange(location: NSNotFound, length: 1)))
        let empty = try XCTUnwrap(MarkdownFootnoteInsertion.plan(in: "",
            selection: NSRange(location: 0, length: 0)))
        XCTAssertEqual(empty.applying(to: ""), "[^fn1]\n\n[^fn1]: ")
    }
}
