import AppKit
import SwiftUI
import XCTest
@testable import MKTownEditor

final class MarkdownRendererTests: XCTestCase {
    @MainActor
    func testFootnoteReferencesRenderInOrderWithBacklinks() {
        let markdown = "Body[^b] and `[^b]`.\n\n[^b]: Explanation"
        let rendered = MarkdownRenderer.render(markdown)
        XCTAssertTrue(rendered.string.contains("Body1 and [^b]"))
        XCTAssertTrue(rendered.string.contains("脚注\n1. Explanation ↩"))
        XCTAssertFalse(rendered.string.contains("[^b]:"))
        let html = MarkdownHTMLExporter.render(markdown)
        XCTAssertTrue(html.contains("id=\"fnref-1\" href=\"#fn-1\""))
        XCTAssertTrue(html.contains("id=\"fn-1\""))
        XCTAssertTrue(html.contains("href=\"#fnref-1\""))
        XCTAssertFalse(html.contains("[^b]:"))
    }

    @MainActor
    func testCalloutRendersLabelAndIconSemanticsInPreviewAndHTML() {
        let source = "> [!TIP]\n> Try this"
        let rendered = MarkdownRenderer.render(source)
        XCTAssertTrue(rendered.string.contains("ヒント"))
        XCTAssertTrue(rendered.string.contains("Try this"))
        XCTAssertFalse(rendered.string.contains("[!TIP]"))
        let html = MarkdownHTMLExporter.render(source)
        XCTAssertTrue(html.contains("<aside class=\"callout\" aria-label=\"ヒント\""))
        XCTAssertFalse(html.contains("[!TIP]"))
    }

    @MainActor
    func testBareAutolinksExcludePunctuationAndCodeInPreviewAndHTML() {
        let markdown = "Visit www.commonmark.org/help. See https://example.com/a(b)). Mail a+tag@bar.example. `https://code.example`"
        let rendered = MarkdownRenderer.render(markdown)
        let text = rendered.string as NSString
        func link(_ token: String) -> URL? {
            let range = text.range(of: token)
            return rendered.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        }
        XCTAssertEqual(link("www.commonmark.org/help"), URL(string: "http://www.commonmark.org/help"))
        XCTAssertEqual(link("https://example.com/a(b)"), URL(string: "https://example.com/a(b)"))
        XCTAssertEqual(link("a+tag@bar.example"), URL(string: "mailto:a+tag@bar.example"))
        XCTAssertNil(link("https://code.example"))
        let html = MarkdownHTMLExporter.render(markdown)
        XCTAssertTrue(html.contains("href=\"http://www.commonmark.org/help\""))
        XCTAssertTrue(html.contains("href=\"mailto:a+tag@bar.example\""))
        XCTAssertFalse(html.contains("href=\"https://code.example\""))
    }

    @MainActor
    func testBareURLRequiresGFMDelimiter() {
        let rendered = MarkdownRenderer.render("prefixhttps://example.com and https://valid.example")
        let text = rendered.string as NSString
        XCTAssertNil(rendered.attribute(.link, at: text.range(of: "prefixhttps").location,
            effectiveRange: nil))
        XCTAssertEqual(rendered.attribute(.link, at: text.range(of: "https://valid.example").location,
            effectiveRange: nil) as? URL, URL(string: "https://valid.example"))
    }

    @MainActor
    func testExplicitMailtoAndInvalidDomainAreNotMislinked() {
        let rendered = MarkdownRenderer.render("mailto:a.b-c_d@mail.example and www.invalid_foo.bar and www.good.example")
        let text = rendered.string as NSString
        XCTAssertEqual(rendered.attribute(.link, at: text.range(of: "mailto:a.b-c_d@mail.example").location,
            effectiveRange: nil) as? URL, URL(string: "mailto:a.b-c_d@mail.example"))
        XCTAssertNil(rendered.attribute(.link, at: text.range(of: "www.invalid_foo.bar").location,
            effectiveRange: nil))
        XCTAssertNotNil(rendered.attribute(.link, at: text.range(of: "www.good.example").location,
            effectiveRange: nil))
    }

    func testParserRecognizesCommonBlockTypes() {
        let blocks = MarkdownAnalysis("# Title\n> Quote\n- Item\n2. Second\n---").rootBlocks

        XCTAssertEqual(blocks.map(\.kind), [
            .heading(level: 1),
            .quote,
            .unorderedList,
            .orderedList(number: 2),
            .horizontalRule
        ])
    }

    func testParserKeepsFencedCodeTogether() {
        let source = "```swift\nlet value = 1\nprint(value)\n```"
        let blocks = MarkdownAnalysis(source).blocks

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks[0].kind, .codeBlock)
        XCTAssertEqual(blocks[0].content, "let value = 1\nprint(value)")
        XCTAssertEqual(blocks[0].codeLanguage, "swift")
        XCTAssertEqual(blocks[0].sourceRange, NSRange(location: 0, length: (source as NSString).length))
    }

    @MainActor
    func testRendererRemovesMarkdownMarkersAndKeepsStructure() {
        let rendered = MarkdownRenderer.render("# **Title**\n\n- Item")

        XCTAssertEqual(rendered.string, "Title\n\n•  Item")
        XCTAssertNotNil(rendered.attribute(.font, at: 0, effectiveRange: nil))
    }

    @MainActor
    func testRendererDistinguishesSoftAndHardParagraphBreaks() {
        let rendered = MarkdownRenderer.render("first\nsecond  \nthird\\\nfourth\n\nnext")

        XCTAssertEqual(rendered.string, "first second\nthird\nfourth\n\nnext")
    }

    @MainActor
    func testNestedListAndContinuationAreVisuallyIndented() {
        let rendered = MarkdownRenderer.render("- parent\n  - child\n\n    continuation")
        let source = rendered.string as NSString
        let parent = rendered.attribute(.paragraphStyle, at: source.range(of: "parent").location,
                                        effectiveRange: nil) as? NSParagraphStyle
        let child = rendered.attribute(.paragraphStyle, at: source.range(of: "child").location,
                                       effectiveRange: nil) as? NSParagraphStyle
        let continuation = rendered.attribute(.paragraphStyle, at: source.range(of: "continuation").location,
                                              effectiveRange: nil) as? NSParagraphStyle

        XCTAssertEqual(rendered.string, "•  parent\n•  child\n\ncontinuation")
        XCTAssertGreaterThan(child?.firstLineHeadIndent ?? 0, parent?.firstLineHeadIndent ?? 0)
        XCTAssertGreaterThan(continuation?.firstLineHeadIndent ?? 0, child?.firstLineHeadIndent ?? 0)
    }

    @MainActor
    func testListParagraphContinuesOnNextLineWithoutExtraBullet() {
        let rendered = MarkdownRenderer.render("- parent\n  continued\n  - child")

        XCTAssertEqual(rendered.string, "•  parent continued\n•  child")
    }

    @MainActor
    func testQuoteRendersMultipleParagraphsListsCodeAndNestedQuote() {
        let markdown = "> first\n> second\n>\n> - item\n>   - child\n>\n> ```swift\n> let x = 1\n> ```\n>> nested"

        XCTAssertEqual(MarkdownRenderer.render(markdown).string,
                       "│  first second\n│  \n│  •  item\n│  •  child\n│  \n│  let x = 1\n│  │  nested")
    }

    @MainActor
    func testQuoteLazyContinuationAndOutsideParagraph() {
        XCTAssertEqual(MarkdownRenderer.render("> first\nsecond\n>\noutside").string,
                       "│  first second\n│  \noutside")
    }

    @MainActor
    func testIndentedAndFencedCodeRenderLiteralMarkdown() {
        let output = MarkdownRenderer.render("    **literal**\n\n    _again_\n\n~~~~python\n# text\n~~~~~")

        XCTAssertEqual(output.string, "**literal**\n\n_again_\n\n# text")
    }

    @MainActor
    func testIndentedCodeInsideListKeepsLiteralContent() {
        XCTAssertEqual(MarkdownRenderer.render("- item\n      **code**\n- next").string,
                       "•  item\n**code**\n•  next")
    }

    @MainActor
    func testSetextAndATXClosingMarkersRenderAsHeadings() {
        let rendered = MarkdownRenderer.render("first\nsecond\n---\n## title ###")

        XCTAssertEqual(rendered.string, "first second\ntitle")
        XCTAssertNotNil(rendered.attribute(.font, at: 0, effectiveRange: nil))
    }

    @MainActor
    func testTableFallbackRendersCellsWithoutDelimiterSyntax() {
        XCTAssertEqual(MarkdownRenderer.render("a|b\n---|---\n1|2").string, "a\tb\n1\t2")
    }

    @MainActor
    func testTablePreviewHasNestedHorizontalScrollArea() {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            let current = (view as? NSScrollView).map { [$0] } ?? []
            return current + view.subviews.flatMap(scrollViews(in:))
        }
        for markdown in [
            "a|b|c\n-|-|-\n1|2|3",
            "> a|b|c\n> -|-|-\n> 1|2|3",
            "- item\n  a|b|c\n  -|-|-\n  1|2|3"
        ] {
            let preview = MarkdownPreview(markdown: markdown, documentContext: DocumentContext(fileURL: nil))
            let host = NSHostingView(rootView: preview)
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 240)
            host.layoutSubtreeIfNeeded()

            let areas = scrollViews(in: host)
            XCTAssertGreaterThanOrEqual(areas.count, 2)
            XCTAssertTrue(areas.contains(where: \.hasHorizontalScroller))
        }
    }

    @MainActor
    func testTasksShowExplicitStateForKeyboardAndVoiceOverReading() {
        let markdown = "- [ ] first\n  - [x] child\n2. [X] done\n- plain"

        XCTAssertEqual(MarkdownRenderer.render(markdown).string,
                       "☐ 未完了  first\n☑ 完了  child\n2.  ☑ 完了  done\n•  plain")
    }

    @MainActor
    func testTaskContentCanRenderBesideInteractivePreviewControl() {
        let markdown = "- [x] **done**"
        let analysis = MarkdownAnalysis(markdown)
        let block = try! XCTUnwrap(analysis.blocks.first(where: { $0.task != nil }))

        let content = MarkdownRenderer.renderLeaf(block, in: analysis, showTaskPrefix: false)
        XCTAssertEqual(content.string, "done")
        let range = (content.string as NSString).range(of: "done")
        XCTAssertNotNil(content.attribute(.font, at: range.location, effectiveRange: nil))

        let numbered = MarkdownAnalysis("3. [ ] next")
        let numberedTask = try! XCTUnwrap(numbered.blocks.first(where: { $0.task != nil }))
        XCTAssertEqual(MarkdownRenderer.renderLeaf(numberedTask, in: numbered,
                                                   showTaskPrefix: false).string, "3.  next")
    }

    @MainActor
    func testTaskPreviewBuildsNativeBlockLayout() {
        let preview = MarkdownPreview(markdown: "- [ ] item\n1. [x] done",
                                      documentContext: DocumentContext(fileURL: nil),
                                      onToggleTask: { _ in })
        let host = NSHostingView(rootView: preview)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
        host.layoutSubtreeIfNeeded()

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }
        XCTAssertTrue(descendants(of: host).contains(where: { $0 is NSScrollView }))
        XCTAssertFalse(descendants(of: host).contains(where: { $0 is NSTextView }))
    }


    @MainActor
    func testGFMStrikethroughRendersWithAttribute() {
        let output = MarkdownRenderer.render("before ~~削除🙂~~ after")
        let range = (output.string as NSString).range(of: "削除🙂")

        XCTAssertEqual(output.string, "before 削除🙂 after")
        XCTAssertNotEqual(range.location, NSNotFound)
        if range.location != NSNotFound {
            XCTAssertNotNil(output.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil))
        }
    }

    @MainActor
    func testInlineIntentConversionAlsoPreservesBoldItalicAndCode() {
        let output = MarkdownRenderer.render("**bold** *italic* `code` ~~struck~~")
        let text = output.string as NSString
        let bold = text.range(of: "bold").location
        let italic = text.range(of: "italic").location
        let code = text.range(of: "code").location
        let struck = text.range(of: "struck").location

        XCTAssertTrue(NSFontManager.shared.traits(of: output.attribute(.font, at: bold,
            effectiveRange: nil) as! NSFont).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: output.attribute(.font, at: italic,
            effectiveRange: nil) as! NSFont).contains(.italicFontMask))
        XCTAssertNotNil(output.attribute(.backgroundColor, at: code, effectiveRange: nil))
        XCTAssertNotNil(output.attribute(.strikethroughStyle, at: struck, effectiveRange: nil))
    }

    @MainActor
    func testFullCollapsedShortcutAndImageReferencesResolveWithLaterDefinitions() {
        let markdown = "[Full][Key] [key][] [KEY] ![photo][key]\n\n[KEY]: https://example.com/photo.png"
        let rendered = MarkdownRenderer.render(markdown)
        let text = rendered.string as NSString

        XCTAssertEqual(rendered.string, "Full key KEY 外部画像の読込オフ: photo\n")
        for label in ["Full", "key", "KEY", "外部画像の読込オフ: photo"] {
            let range = text.range(of: label)
            XCTAssertNotEqual(range.location, NSNotFound)
            if range.location != NSNotFound {
                XCTAssertEqual(rendered.attribute(.link, at: range.location, effectiveRange: nil) as? URL,
                               URL(string: "https://example.com/photo.png"))
            }
        }
    }

    @MainActor
    func testReferenceResolutionLeavesInlineLinksAndUnknownLabelsAlone() {
        let markdown = "[known](https://example.com/inline) [unknown] [known]\n\n[known]: /reference"
        let rendered = MarkdownRenderer.render(markdown)
        let text = rendered.string as NSString

        XCTAssertEqual(rendered.string, "known [unknown] known\n")
        XCTAssertEqual(rendered.attribute(.link, at: text.range(of: "known").location,
            effectiveRange: nil) as? URL, URL(string: "https://example.com/inline"))
        XCTAssertEqual(rendered.attribute(.link, at: text.range(of: "known", options: .backwards).location,
            effectiveRange: nil) as? URL, URL(string: "/reference"))
    }

    @MainActor
    func testReferenceSyntaxInsideCodeSpanRemainsLiteral() {
        let rendered = MarkdownRenderer.render("`[ref]` [ref]\n\n[ref]: /url")
        let text = rendered.string as NSString

        XCTAssertEqual(rendered.string, "[ref] ref\n")
        XCTAssertNil(rendered.attribute(.link, at: text.range(of: "[ref]").location,
            effectiveRange: nil))
        XCTAssertEqual(rendered.attribute(.link, at: text.range(of: "ref", options: .backwards).location,
            effectiveRange: nil) as? URL, URL(string: "/url"))
    }

    @MainActor
    func testReferencesResolveInsideQuotesListsAndTableCells() {
        let markdown = "> [quoted][Ref]\n- [listed][ref]\n\n| Link |\n| --- |\n| [cell][REF] |\n\n[ref]: https://example.com"
        let analysis = MarkdownAnalysis(markdown)
        let rendered = MarkdownRenderer.render(markdown)
        let text = rendered.string as NSString

        for label in ["quoted", "listed"] {
            let range = text.range(of: label)
            XCTAssertNotEqual(range.location, NSNotFound)
            if range.location != NSNotFound {
                XCTAssertEqual(rendered.attribute(.link, at: range.location,
                    effectiveRange: nil) as? URL, URL(string: "https://example.com"))
            }
        }
        let cell = MarkdownRenderer.renderTableCell("[cell][REF]", in: analysis)
        XCTAssertEqual(cell.string, "cell")
        XCTAssertEqual(cell.attribute(.link, at: 0, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))
    }

    @MainActor
    func testEscapedBackticksDoNotHideReferenceLinks() {
        let rendered = MarkdownRenderer.render("\\`[ref]\\`\n\n[ref]: /url")
        let range = (rendered.string as NSString).range(of: "ref")

        XCTAssertNotEqual(range.location, NSNotFound)
        if range.location != NSNotFound {
            XCTAssertEqual(rendered.attribute(.link, at: range.location,
                effectiveRange: nil) as? URL, URL(string: "/url"))
        }
    }

    /// 不具合: コールアウト内のコードブロックはコールアウト全体の文字列に含まれ、枠もコピーボタンもなく、
    /// 文字ごとの背景の帯で表示されていた。直下のコードブロックは別の部分として返し、プレビューが枠で囲む。
    @MainActor
    func testCalloutSegmentsSeparateDirectCodeBlocks() throws {
        let analysis = MarkdownAnalysis("> [!NOTE]\n> before\n>\n> ```swift\n> let x = 1\n> ```\n>\n> after\n")
        let callout = try XCTUnwrap(analysis.blocks.first { $0.calloutKind != nil })
        let code = try XCTUnwrap(analysis.blocks.first { $0.kind == .codeBlock })
        let segments = MarkdownRenderer.renderCalloutSegments(callout, in: analysis,
                                                              documentContext: DocumentContext(fileURL: nil))
        let texts = segments.compactMap { segment -> String? in
            if case let .text(rendered) = segment { return rendered.string }
            return nil
        }
        let codes = segments.compactMap { segment -> Int? in
            if case let .codeBlock(block) = segment { return block.id }
            return nil
        }
        XCTAssertEqual(codes, [code.id])
        XCTAssertEqual(segments.count, 3)
        XCTAssertTrue(texts[0].contains(try XCTUnwrap(callout.calloutKind).title))
        XCTAssertTrue(texts[0].contains("before"))
        XCTAssertTrue(texts[1].contains("after"))
        XCTAssertFalse(texts.contains { $0.contains("let x") })
        // コードの前後の空行は、引用の印だけの行として残さない。
        XCTAssertFalse(texts[0].hasSuffix("\n") || texts[0].hasSuffix("│  "))
        XCTAssertFalse(texts[1].hasPrefix("│  \n"))
    }

    /// 不具合: コードブロックを含まないコールアウトでも、見出しの直後の空行を除いていた。
    @MainActor
    func testCalloutSegmentsWithoutCodeMatchRenderCallout() throws {
        for markdown in ["> [!NOTE]\n>\n> body\n>\n> more\n", "> [!TIP]\n> - item\n>\n> tail\n>\n"] {
            let analysis = MarkdownAnalysis(markdown)
            let callout = try XCTUnwrap(analysis.blocks.first { $0.calloutKind != nil })
            let context = DocumentContext(fileURL: nil)
            let segments = MarkdownRenderer.renderCalloutSegments(callout, in: analysis, documentContext: context)
            XCTAssertEqual(segments.count, 1, markdown)
            guard case let .text(rendered) = segments.first else { return XCTFail(markdown) }
            XCTAssertEqual(rendered.string,
                           MarkdownRenderer.renderCallout(callout, in: analysis, documentContext: context).string,
                           markdown)
        }
    }

    /// 見出しと本文の間の空行は、後にコードブロックがあっても残す。
    @MainActor
    func testCalloutSegmentsKeepBlankAfterTitleBeforeText() throws {
        let analysis = MarkdownAnalysis("> [!NOTE]\n>\n> body\n>\n> ```\n> code\n> ```\n")
        let callout = try XCTUnwrap(analysis.blocks.first { $0.calloutKind != nil })
        let segments = MarkdownRenderer.renderCalloutSegments(callout, in: analysis,
                                                              documentContext: DocumentContext(fileURL: nil))
        guard case let .text(first) = segments.first else { return XCTFail("先頭は文章の部分") }
        let title = try XCTUnwrap(callout.calloutKind).title
        XCTAssertTrue(first.string.hasPrefix("│  \(title)\n│  \n│  body"), first.string)
        XCTAssertFalse(first.string.hasSuffix("│  "))
    }

    @MainActor
    func testCalloutSegmentsKeepTitleWhenCalloutStartsWithCodeAndNestedCodeInText() throws {
        let leading = MarkdownAnalysis("> [!TIP]\n> ```\n> code\n> ```\n")
        let callout = try XCTUnwrap(leading.blocks.first { $0.calloutKind != nil })
        let segments = MarkdownRenderer.renderCalloutSegments(callout, in: leading,
                                                              documentContext: DocumentContext(fileURL: nil))
        XCTAssertEqual(segments.count, 2)
        guard case let .text(title) = segments[0], case .codeBlock = segments[1] else {
            return XCTFail("見出しの後にコードブロックが続く")
        }
        XCTAssertTrue(title.string.contains(try XCTUnwrap(callout.calloutKind).title))

        // リスト項目の下に字下げしたコードブロックは項目の子になるが、これも分けて枠で囲む。
        let listed = MarkdownAnalysis("> [!NOTE]\n> - item\n>\n>       indented code\n>\n> after\n")
        let listedCode = try XCTUnwrap(listed.blocks.first { $0.kind == .codeBlock })
        let listedCallout = try XCTUnwrap(listed.blocks.first { $0.calloutKind != nil })
        XCTAssertNotNil(listedCode.parentID)
        XCTAssertNotEqual(listedCode.parentID, listedCallout.id, "コールアウトの孫として解析される")
        let listedSegments = MarkdownRenderer.renderCalloutSegments(listedCallout, in: listed,
                                                                    documentContext: DocumentContext(fileURL: nil))
        let listedCodes = listedSegments.compactMap { segment -> Int? in
            if case let .codeBlock(block) = segment { return block.id }
            return nil
        }
        XCTAssertEqual(listedCodes, [listedCode.id])
        let listedTexts = listedSegments.compactMap { segment -> String? in
            if case let .text(rendered) = segment { return rendered.string }
            return nil
        }
        XCTAssertTrue(listedTexts.first?.contains("item") == true)
        XCTAssertTrue(listedTexts.last?.contains("after") == true)
        XCTAssertFalse(listedTexts.contains { $0.contains("indented code") })

        // 入れ子の引用の中のコードブロックは文章の部分に含め、従来どおり描画する。
        let nested = MarkdownAnalysis("> [!NOTE]\n> > ```\n> > nested\n> > ```\n")
        let nestedCallout = try XCTUnwrap(nested.blocks.first { $0.calloutKind != nil })
        let nestedSegments = MarkdownRenderer.renderCalloutSegments(nestedCallout, in: nested,
                                                                    documentContext: DocumentContext(fileURL: nil))
        XCTAssertNotNil(nested.blocks.first { $0.kind == .codeBlock })
        XCTAssertFalse(nestedSegments.contains { if case .codeBlock = $0 { true } else { false } })
    }
}
