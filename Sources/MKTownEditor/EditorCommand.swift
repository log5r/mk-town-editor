import SwiftUI

enum EditorCommand: Hashable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case footnote
    case heading(level: Int)
    case quote
    case plainBlock
    case removeFormatting
    case tableOfContents
    case renumberList
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

    static let toolbar: [Self] = [.bold, .italic, .link]
    static let context: [Self] = [.bold, .italic, .strikethrough, .inlineCode, .removeFormatting, .link, .footnote, .image, .table, .quote, .plainBlock, .unorderedList, .orderedList, .taskList, .renumberList, .indentList, .outdentList, .toggleTaskCompletion, .horizontalRule]

    var title: String {
        switch self {
        case .bold: "太字"
        case .italic: "斜体"
        case .strikethrough: "取り消し線"
        case .inlineCode: "インラインコード"
        case .link: "リンク"
        case .footnote: "脚注を挿入"
        case let .heading(level): level == 0 ? "本文" : "見出し \(level)"
        case .quote: "引用"
        case .plainBlock: "本文に戻す"
        case .removeFormatting: "書式を除去"
        case .tableOfContents: "目次を生成・更新"
        case .renumberList: "番号付きリストを再採番"
        case .unorderedList: "箇条書き"
        case .orderedList: "番号付きリスト"
        case .taskList: "タスクリスト"
        case .indentList: "インデントを増やす"
        case .outdentList: "インデントを減らす"
        case .toggleTaskCompletion: "タスクの完了を切り替え"
        case let .codeBlock(language): language.map { "\($0.title) コードブロック" } ?? "言語なし"
        case .horizontalRule: "区切り線"
        case .image: "画像…"
        case .table: "表…"
        case .find: "検索…"
        }
    }

    var symbolName: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .inlineCode: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .footnote: "text.badge.plus"
        case .heading: "number"
        case .quote: "text.quote"
        case .plainBlock: "text.alignleft"
        case .removeFormatting: "textformat"
        case .tableOfContents: "list.bullet.indent"
        case .renumberList: "list.number"
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
        case .footnote: nil
        case let .heading(level): (KeyEquivalent(Character(String(level))), [.command, .option])
        case .quote: (">", [.command, .shift])
        case .plainBlock: nil
        case .removeFormatting: nil
        case .tableOfContents: nil
        case .renumberList: nil
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
        case .footnote: model.insertFootnote()
        case let .heading(level): model.apply(.heading(level: level))
        case .quote: model.apply(.quote)
        case .plainBlock: model.apply(.plainBlock)
        case .removeFormatting: model.apply(.removeFormatting)
        case .tableOfContents: model.apply(.tableOfContents)
        case .renumberList: model.apply(.renumberList)
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
