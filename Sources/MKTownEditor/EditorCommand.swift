import SwiftUI

enum EditorCommand: Hashable {
    case bold
    case italic
    case strikethrough
    case highlight
    case superscript
    case subscriptText
    case inlineCode
    case link
    case convertLinkForm
    case footnote
    case heading(level: Int)
    case quote
    case plainBlock
    case removeFormatting
    case tableOfContents
    case renumberList
    case duplicateLines
    case moveLinesUp
    case moveLinesDown
    case deleteLines
    case sortLinesAscending
    case reverseLines
    case removeDuplicateLines
    case joinLines
    case sortLinesWithOptions
    case comment
    case expandSelection
    case shrinkSelection
    case selectNextOccurrence
    case toggleFold
    case unfoldAll
    case snippet
    case commandPalette
    case unorderedList
    case orderedList
    case taskList
    case indentList
    case outdentList
    case trimTrailingWhitespace
    case convertIndentationToSpaces
    case convertIndentationToTabs
    case toggleTaskCompletion
    case codeBlock(language: MarkdownCodeLanguage?)
    case horizontalRule
    case image
    case table
    case find
    case inspectUnicode
    case insertUnicode
    case transformSelection(EditorTextTransformation)

    static let toolbar: [Self] = [
        .bold, .italic, .link, .strikethrough, .inlineCode,
        .heading(level: 1), .quote, .unorderedList, .orderedList, .taskList,
        .codeBlock(language: nil), .horizontalRule, .image, .table, .footnote
    ]
    static let defaultToolbar: Set<Self> = [.bold, .italic, .link]

    var toolbarIdentifier: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .link: "link"
        case .strikethrough: "strikethrough"
        case .inlineCode: "inline-code"
        case let .heading(level): "heading-\(level)"
        case .quote: "quote"
        case .unorderedList: "unordered-list"
        case .orderedList: "ordered-list"
        case .taskList: "task-list"
        case let .codeBlock(language): "code-block-\(language?.rawValue ?? "plain")"
        case .horizontalRule: "horizontal-rule"
        case .image: "image"
        case .table: "table"
        case .footnote: "footnote"
        case .sortLinesAscending: "sort-lines-ascending"
        case .reverseLines: "reverse-lines"
        case .removeDuplicateLines: "remove-duplicate-lines"
        case .joinLines: "join-lines"
        case .sortLinesWithOptions: "sort-lines-with-options"
        case .selectNextOccurrence: "select-next-occurrence"
        case .trimTrailingWhitespace: "trim-trailing-whitespace"
        case .convertIndentationToSpaces: "convert-indentation-to-spaces"
        case .convertIndentationToTabs: "convert-indentation-to-tabs"
        case .inspectUnicode: "inspect-unicode"
        case .insertUnicode: "insert-unicode"
        case let .transformSelection(transformation): "transform-selection-\(transformation.rawValue)"
        default: "other-\(String(describing: self))"
        }
    }
    static let textTransformations = EditorTextTransformation.allCases.map(Self.transformSelection)
    static let palette: [Self] = [
        .bold, .italic, .strikethrough, .highlight, .superscript, .subscriptText,
        .inlineCode, .removeFormatting,
        .link, .convertLinkForm, .footnote, .image, .table, .snippet,
        .heading(level: 0), .heading(level: 1), .heading(level: 2),
        .heading(level: 3), .heading(level: 4), .heading(level: 5), .heading(level: 6),
        .quote, .plainBlock, .unorderedList, .orderedList, .taskList,
        .renumberList, .indentList, .outdentList, .toggleTaskCompletion,
        .codeBlock(language: nil), .horizontalRule, .comment,
        .tableOfContents, .duplicateLines, .moveLinesUp, .moveLinesDown,
        .deleteLines, .sortLinesAscending, .reverseLines, .removeDuplicateLines, .joinLines,
        .sortLinesWithOptions, .trimTrailingWhitespace, .convertIndentationToSpaces, .convertIndentationToTabs,
        .expandSelection, .shrinkSelection, .selectNextOccurrence, .toggleFold,
        .unfoldAll, .find, .inspectUnicode, .insertUnicode
    ] + textTransformations + MarkdownCodeLanguage.allCases.map { .codeBlock(language: $0) }
    /// The editor's context menu stays short: inline formatting, links and images, and list
    /// toggles. Everything else is in its "Markdown" submenu.
    static let contextGroups: [[Self]] = [
        [.bold, .italic, .strikethrough, .inlineCode],
        [.link, .image],
        [.unorderedList, .orderedList, .taskList]
    ]
    static let context: [Self] = contextGroups.flatMap { $0 }
    static let contextMarkdown: [Self] = [.highlight, .superscript, .subscriptText, .removeFormatting, .selectNextOccurrence, .convertLinkForm, .footnote, .table, .quote, .plainBlock, .renumberList, .indentList, .outdentList, .toggleTaskCompletion, .horizontalRule]

    var title: String {
        switch self {
        case .bold: String(localized: "太字")
        case .italic: String(localized: "斜体")
        case .strikethrough: String(localized: "取り消し線")
        case .highlight: String(localized: "ハイライト")
        case .superscript: String(localized: "上付き")
        case .subscriptText: String(localized: "下付き")
        case .inlineCode: String(localized: "インラインコード")
        case .link: String(localized: "リンク")
        case .convertLinkForm: String(localized: "参照形式／インライン形式を変換")
        case .footnote: String(localized: "脚注を挿入")
        case let .heading(level): level == 0 ? String(localized: "本文") : String(localized: "見出し \(level)")
        case .quote: String(localized: "引用")
        case .plainBlock: String(localized: "本文に戻す")
        case .removeFormatting: String(localized: "書式を除去")
        case .tableOfContents: String(localized: "目次を生成・更新")
        case .renumberList: String(localized: "番号付きリストを再採番")
        case .duplicateLines: String(localized: "行を複製")
        case .moveLinesUp: String(localized: "行を上へ移動")
        case .moveLinesDown: String(localized: "行を下へ移動")
        case .deleteLines: String(localized: "行を削除")
        case .sortLinesAscending: String(localized: "行を昇順に並べ替え")
        case .reverseLines: String(localized: "行を逆順にする")
        case .removeDuplicateLines: String(localized: "重複行を削除")
        case .joinLines: String(localized: "行を結合")
        case .sortLinesWithOptions: String(localized: "条件を指定して行を並べ替え…")
        case .comment: String(localized: "コメントにする／解除")
        case .expandSelection: String(localized: "選択範囲を拡大")
        case .shrinkSelection: String(localized: "選択範囲を縮小")
        case .selectNextOccurrence: String(localized: "次の同じ文字列を選択")
        case .toggleFold: String(localized: "見出し・コードを折りたたむ／展開")
        case .unfoldAll: String(localized: "すべて展開")
        case .snippet: String(localized: "スニペットを挿入…")
        case .commandPalette: String(localized: "コマンドパレット…")
        case .unorderedList: String(localized: "箇条書き")
        case .orderedList: String(localized: "番号付きリスト")
        case .taskList: String(localized: "タスクリスト")
        case .indentList: String(localized: "インデントを増やす")
        case .outdentList: String(localized: "インデントを減らす")
        case .trimTrailingWhitespace: String(localized: "行末の空白を削除")
        case .convertIndentationToSpaces: String(localized: "字下げをスペースに変換")
        case .convertIndentationToTabs: String(localized: "字下げをタブに変換")
        case .toggleTaskCompletion: String(localized: "タスクの完了を切り替え")
        case let .codeBlock(language): language.map { String(localized: "\($0.title) コードブロック") } ?? String(localized: "言語なし")
        case .horizontalRule: String(localized: "区切り線")
        case .image: String(localized: "画像…")
        case .table: String(localized: "表…")
        case .find: String(localized: "検索…")
        case .inspectUnicode: String(localized: "選択した文字のUnicode情報を表示")
        case .insertUnicode: String(localized: "コードポイントから文字を挿入…")
        case .transformSelection(.uppercase): String(localized: "大文字にする")
        case .transformSelection(.lowercase): String(localized: "小文字にする")
        case .transformSelection(.capitalized): String(localized: "語頭を大文字にする")
        case .transformSelection(.fullwidthToHalfwidth): String(localized: "半角にする")
        case .transformSelection(.halfwidthToFullwidth): String(localized: "全角にする")
        case .transformSelection(.hiraganaToKatakana): String(localized: "カタカナにする")
        case .transformSelection(.katakanaToHiragana): String(localized: "ひらがなにする")
        case .transformSelection(.nfc): String(localized: "NFCに正規化")
        case .transformSelection(.nfd): String(localized: "NFDに正規化")
        case .transformSelection(.nfkc): String(localized: "NFKCに正規化")
        case .transformSelection(.nfkd): String(localized: "NFKDに正規化")
        }
    }

    var symbolName: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .highlight: "highlighter"
        case .superscript: "textformat.superscript"
        case .subscriptText: "textformat.subscript"
        case .inlineCode: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .convertLinkForm: "arrow.left.arrow.right"
        case .footnote: "text.badge.plus"
        case .heading: "number"
        case .quote: "text.quote"
        case .plainBlock: "text.alignleft"
        case .removeFormatting: "textformat"
        case .tableOfContents: "list.bullet.indent"
        case .renumberList: "list.number"
        case .duplicateLines: "plus.square.on.square"
        case .moveLinesUp: "arrow.up"
        case .moveLinesDown: "arrow.down"
        case .deleteLines: "trash"
        case .sortLinesAscending: "arrow.down"
        case .reverseLines: "arrow.up.arrow.down"
        case .removeDuplicateLines: "minus.square"
        case .joinLines: "arrow.turn.down.right"
        case .sortLinesWithOptions: "slider.horizontal.3"
        case .comment: "text.bubble"
        case .expandSelection: "arrow.up.left.and.arrow.down.right"
        case .shrinkSelection: "arrow.down.right.and.arrow.up.left"
        case .selectNextOccurrence: "text.cursor"
        case .toggleFold: "chevron.right"
        case .unfoldAll: "chevron.down"
        case .snippet: "text.insert"
        case .commandPalette: "command"
        case .unorderedList: "list.bullet"
        case .orderedList: "list.number"
        case .taskList: "checklist"
        case .indentList: "increase.indent"
        case .outdentList: "decrease.indent"
        case .trimTrailingWhitespace: "text.alignleft"
        case .convertIndentationToSpaces: "space"
        case .convertIndentationToTabs: "arrow.right.to.line"
        case .toggleTaskCompletion: "checkmark.square"
        case .codeBlock: "curlybraces.square"
        case .horizontalRule: "minus"
        case .image: "photo"
        case .table: "tablecells"
        case .find: "magnifyingglass"
        case .inspectUnicode: "info.circle"
        case .insertUnicode: "text.insert"
        case .transformSelection: "textformat"
        }
    }

    var shortcut: (key: KeyEquivalent, modifiers: EventModifiers)? {
        switch self {
        case .bold: ("b", .command)
        case .italic: ("i", .command)
        case .strikethrough: ("x", [.command, .shift])
        case .highlight, .superscript, .subscriptText: nil
        // ⌘` moves between windows system-wide, so inline code takes ⇧⌘C.
        case .inlineCode: ("c", [.command, .shift])
        case .link: ("k", .command)
        case .convertLinkForm: nil
        case .footnote: nil
        case let .heading(level): (KeyEquivalent(Character(String(level))), [.command, .option])
        // ">" already implies whatever modifier the layout needs; adding Shift to "." instead
        // would never match, because AppKit compares the shifted character.
        case .quote: (">", .command)
        case .plainBlock: nil
        case .removeFormatting: nil
        case .tableOfContents: nil
        case .renumberList: nil
        case .duplicateLines, .moveLinesUp, .moveLinesDown, .deleteLines: nil
        case .sortLinesAscending, .reverseLines, .removeDuplicateLines, .joinLines, .sortLinesWithOptions: nil
        case .comment: nil
        case .expandSelection, .shrinkSelection, .selectNextOccurrence: nil
        case .toggleFold, .unfoldAll: nil
        case .snippet: nil
        case .commandPalette: ("p", [.command, .shift])
        case .unorderedList: ("8", [.command, .shift])
        case .orderedList: ("7", [.command, .shift])
        case .taskList: ("9", [.command, .shift])
        case .indentList, .outdentList, .trimTrailingWhitespace,
             .convertIndentationToSpaces, .convertIndentationToTabs: nil
        // ⌥⌘T shows or hides the toolbar; Notes uses ⇧⌘U to check an item.
        case .toggleTaskCompletion: ("u", [.command, .shift])
        case let .codeBlock(language): language == nil ? ("`", [.command, .option]) : nil
        case .horizontalRule: nil
        case .image: nil
        case .table: nil
        case .find: ("f", .command)
        case .inspectUnicode, .insertUnicode, .transformSelection: nil
        }
    }

    var shortcutLabel: String? {
        guard let shortcut else { return nil }
        var label = ""
        if shortcut.modifiers.contains(.control) { label += "⌃" }
        if shortcut.modifiers.contains(.option) { label += "⌥" }
        if shortcut.modifiers.contains(.shift) { label += "⇧" }
        if shortcut.modifiers.contains(.command) { label += "⌘" }
        return label + String(shortcut.key.character).uppercased()
    }

    @MainActor
    static func paletteMatches(_ query: String, in model: MarkdownEditorModel?,
                               shortcutLabel: (Self) -> String? = { $0.shortcutLabel }) -> [Self] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return palette.filter { $0.canExecute(in: model) }.filter { command in
                (term.isEmpty || command.title.localizedStandardContains(term) ||
                    shortcutLabel(command)?.localizedStandardContains(term) == true)
        }
    }

    @MainActor
    func canExecute(in model: MarkdownEditorModel?) -> Bool {
        if self == .find { return model?.hasActiveEditor == true }
        if self == .inspectUnicode { return model?.canInspectUnicode == true }
        if model?.canExecuteMultiSelectionCommand == true {
            switch self {
            case .bold, .italic, .strikethrough, .inlineCode,
                 .commandPalette, .unfoldAll: return true
            case .selectNextOccurrence: return model?.canAddNextOccurrence == true
            default: return false
            }
        }
        guard model?.canExecuteCommand == true else { return false }
        switch self {
        case .selectNextOccurrence: return model?.canAddNextOccurrence == true
        case .indentList, .outdentList, .convertLinkForm:
            return model?.canExecuteStructuralCommand(self) == true
        case .trimTrailingWhitespace:
            return model?.canTrimTrailingWhitespace == true
        case .convertIndentationToSpaces:
            return model?.canConvertIndentation(to: .spaces) == true
        case .convertIndentationToTabs:
            return model?.canConvertIndentation(to: .tabs) == true
        case .comment:
            return model?.canComment == true
        case .snippet:
            return !(model?.snippets.isEmpty ?? true)
        case .transformSelection:
            return model?.canTransformSelection == true
        default: return true
        }
    }

    @MainActor
    func perform(on model: MarkdownEditorModel?) {
        guard canExecute(in: model), let model else { return }
        switch self {
        case .bold: model.apply(.bold)
        case .italic: model.apply(.italic)
        case .strikethrough: model.apply(.strikethrough)
        case .highlight: model.apply(.highlight)
        case .superscript: model.apply(.superscript)
        case .subscriptText: model.apply(.subscriptText)
        case .inlineCode: model.apply(.inlineCode)
        case .link: model.presentLinkEditor()
        case .convertLinkForm: model.convertLinkForm()
        case .footnote: model.insertFootnote()
        case let .heading(level): model.apply(.heading(level: level))
        case .quote: model.apply(.quote)
        case .plainBlock: model.apply(.plainBlock)
        case .removeFormatting: model.apply(.removeFormatting)
        case .tableOfContents: model.apply(.tableOfContents)
        case .renumberList: model.apply(.renumberList)
        case .duplicateLines: model.apply(.duplicateLines)
        case .moveLinesUp: model.apply(.moveLinesUp)
        case .moveLinesDown: model.apply(.moveLinesDown)
        case .deleteLines: model.apply(.deleteLines)
        case .sortLinesAscending: model.apply(.lineOperation(.sortAscending))
        case .reverseLines: model.apply(.lineOperation(.reverse))
        case .removeDuplicateLines: model.apply(.lineOperation(.removeDuplicates))
        case .joinLines: model.apply(.lineOperation(.join))
        case .sortLinesWithOptions: model.presentLineSortOptions()
        case .comment: model.apply(.comment)
        case .expandSelection: model.expandSelection()
        case .shrinkSelection: model.shrinkSelection()
        case .selectNextOccurrence: model.addNextOccurrence()
        case .toggleFold: model.toggleFold()
        case .unfoldAll: model.unfoldAll()
        case .snippet: model.presentSnippetPicker()
        case .commandPalette: model.showingCommandPalette = true
        case .unorderedList: model.apply(.unorderedList)
        case .orderedList: model.apply(.orderedList)
        case .taskList: model.apply(.taskList)
        case .indentList: model.changeIndentation(.indent)
        case .outdentList: model.changeIndentation(.outdent)
        case .trimTrailingWhitespace: model.trimTrailingWhitespace()
        case .convertIndentationToSpaces: model.convertIndentation(to: .spaces)
        case .convertIndentationToTabs: model.convertIndentation(to: .tabs)
        case .toggleTaskCompletion: model.toggleTaskCompletion()
        case let .codeBlock(language): model.apply(.codeBlock(language: language))
        case .horizontalRule: model.apply(.horizontalRule)
        case .image: model.presentImageEditor()
        case .table: model.presentTableEditor()
        case .find: model.showFindBar()
        case .inspectUnicode: model.presentUnicodeInspector()
        case .insertUnicode: model.presentUnicodeInsertion()
        case let .transformSelection(transformation): model.transformSelection(transformation)
        }
    }
}
