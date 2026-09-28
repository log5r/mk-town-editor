import SwiftUI

enum EditorCommand: Hashable {
    case bold
    case italic
    case strikethrough
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
    case comment
    case expandSelection
    case shrinkSelection
    case toggleFold
    case unfoldAll
    case snippet
    case commandPalette
    case unorderedList
    case orderedList
    case taskList
    case indentList
    case outdentList
    case toggleTaskCompletion
    case codeBlock(language: MarkdownCodeLanguage?)
    case horizontalRule
    case image
    case table
    case find

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
        default: "other-\(String(describing: self))"
        }
    }
    static let palette: [Self] = [
        .bold, .italic, .strikethrough, .inlineCode, .removeFormatting,
        .link, .convertLinkForm, .footnote, .image, .table, .snippet,
        .heading(level: 0), .heading(level: 1), .heading(level: 2),
        .heading(level: 3), .heading(level: 4), .heading(level: 5), .heading(level: 6),
        .quote, .plainBlock, .unorderedList, .orderedList, .taskList,
        .renumberList, .indentList, .outdentList, .toggleTaskCompletion,
        .codeBlock(language: nil), .horizontalRule, .comment,
        .tableOfContents, .duplicateLines, .moveLinesUp, .moveLinesDown,
        .deleteLines, .expandSelection, .shrinkSelection, .toggleFold,
        .unfoldAll, .find
    ] + MarkdownCodeLanguage.allCases.map { .codeBlock(language: $0) }
    static let context: [Self] = [.bold, .italic, .strikethrough, .inlineCode, .removeFormatting, .link, .convertLinkForm, .footnote, .image, .table, .quote, .plainBlock, .unorderedList, .orderedList, .taskList, .renumberList, .indentList, .outdentList, .toggleTaskCompletion, .horizontalRule]

    var title: String {
        switch self {
        case .bold: String(localized: "太字")
        case .italic: String(localized: "斜体")
        case .strikethrough: String(localized: "取り消し線")
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
        case .comment: String(localized: "コメントにする／解除")
        case .expandSelection: String(localized: "選択範囲を拡大")
        case .shrinkSelection: String(localized: "選択範囲を縮小")
        case .toggleFold: String(localized: "見出し・コードを折りたたむ／展開")
        case .unfoldAll: String(localized: "すべて展開")
        case .snippet: String(localized: "スニペットを挿入…")
        case .commandPalette: String(localized: "コマンドパレット…")
        case .unorderedList: String(localized: "箇条書き")
        case .orderedList: String(localized: "番号付きリスト")
        case .taskList: String(localized: "タスクリスト")
        case .indentList: String(localized: "インデントを増やす")
        case .outdentList: String(localized: "インデントを減らす")
        case .toggleTaskCompletion: String(localized: "タスクの完了を切り替え")
        case let .codeBlock(language): language.map { String(localized: "\($0.title) コードブロック") } ?? String(localized: "言語なし")
        case .horizontalRule: String(localized: "区切り線")
        case .image: String(localized: "画像…")
        case .table: String(localized: "表…")
        case .find: String(localized: "検索…")
        }
    }

    var symbolName: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
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
        case .comment: "text.bubble"
        case .expandSelection: "arrow.up.left.and.arrow.down.right"
        case .shrinkSelection: "arrow.down.right.and.arrow.up.left"
        case .toggleFold: "chevron.right"
        case .unfoldAll: "chevron.down"
        case .snippet: "text.insert"
        case .commandPalette: "command"
        case .unorderedList: "list.bullet"
        case .orderedList: "list.number"
        case .taskList: "checklist"
        case .indentList: "increase.indent"
        case .outdentList: "decrease.indent"
        case .toggleTaskCompletion: "checkmark.square"
        case .codeBlock: "chevron.left.forwardslash.chevron.right"
        case .horizontalRule: "minus"
        case .image: "photo"
        case .table: "tablecells"
        case .find: "magnifyingglass"
        }
    }

    var shortcut: (key: KeyEquivalent, modifiers: EventModifiers)? {
        switch self {
        case .bold: ("b", .command)
        case .italic: ("i", .command)
        case .strikethrough: ("x", [.command, .shift])
        case .inlineCode: ("`", .command)
        case .link: ("k", .command)
        case .convertLinkForm: nil
        case .footnote: nil
        case let .heading(level): (KeyEquivalent(Character(String(level))), [.command, .option])
        case .quote: (">", [.command, .shift])
        case .plainBlock: nil
        case .removeFormatting: nil
        case .tableOfContents: nil
        case .renumberList: nil
        case .duplicateLines, .moveLinesUp, .moveLinesDown, .deleteLines: nil
        case .comment: nil
        case .expandSelection, .shrinkSelection: nil
        case .toggleFold, .unfoldAll: nil
        case .snippet: nil
        case .commandPalette: ("p", [.command, .shift])
        case .unorderedList: ("8", [.command, .shift])
        case .orderedList: ("7", [.command, .shift])
        case .taskList: ("9", [.command, .shift])
        case .indentList, .outdentList: nil
        case .toggleTaskCompletion: ("t", [.command, .option])
        case let .codeBlock(language): language == nil ? ("`", [.command, .option]) : nil
        case .horizontalRule: nil
        case .image: nil
        case .table: nil
        case .find: ("f", .command)
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
        return palette.filter { command in
            command.canExecute(in: model) &&
                (term.isEmpty || command.title.localizedStandardContains(term) ||
                    shortcutLabel(command)?.localizedStandardContains(term) == true)
        }
    }

    @MainActor
    func canExecute(in model: MarkdownEditorModel?) -> Bool {
        guard model?.canExecuteCommand == true else { return false }
        switch self {
        case .indentList:
            guard let view = model?.textView else { return false }
            return MarkdownIndentation.edit(in: view.string, selection: view.selectedRange(),
                                            direction: .indent) != nil
        case .outdentList:
            guard let view = model?.textView else { return false }
            return MarkdownIndentation.edit(in: view.string, selection: view.selectedRange(),
                                            direction: .outdent) != nil
        case .comment:
            guard let view = model?.textView else { return false }
            return MarkdownFormatter.commentEdit(in: view.string,
                selection: view.selectedRange()) != nil
        case .convertLinkForm:
            guard let view = model?.textView else { return false }
            return MarkdownReferenceConversion.edit(in: view.string,
                selection: view.selectedRange()) != nil
        case .snippet:
            return !(model?.snippets.isEmpty ?? true)
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
        case .comment: model.apply(.comment)
        case .expandSelection: model.expandSelection()
        case .shrinkSelection: model.shrinkSelection()
        case .toggleFold: model.toggleFold()
        case .unfoldAll: model.unfoldAll()
        case .snippet: model.presentSnippetPicker()
        case .commandPalette: model.showingCommandPalette = true
        case .unorderedList: model.apply(.unorderedList)
        case .orderedList: model.apply(.orderedList)
        case .taskList: model.apply(.taskList)
        case .indentList: model.changeIndentation(.indent)
        case .outdentList: model.changeIndentation(.outdent)
        case .toggleTaskCompletion: model.toggleTaskCompletion()
        case let .codeBlock(language): model.apply(.codeBlock(language: language))
        case .horizontalRule: model.apply(.horizontalRule)
        case .image: model.presentImageEditor()
        case .table: model.presentTableEditor()
        case .find: model.showFindBar()
        }
    }
}
