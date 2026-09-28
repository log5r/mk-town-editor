import SwiftUI

enum EditorCommand: Hashable {
    case bold
    case italic
    case strikethrough
    case inlineCode
    case link
    case heading(level: Int)
    case quote
    case unorderedList
    case orderedList
    case taskList
    case toggleTaskCompletion
    case codeBlock(language: MarkdownCodeLanguage?)
    case horizontalRule
    case find

    static let toolbar: [Self] = [.bold, .italic, .link]
    static let context: [Self] = [.bold, .italic, .strikethrough, .inlineCode, .link, .quote, .unorderedList, .orderedList, .taskList, .toggleTaskCompletion, .horizontalRule]

    var title: String {
        switch self {
        case .bold: "太字"
        case .italic: "斜体"
        case .strikethrough: "取り消し線"
        case .inlineCode: "インラインコード"
        case .link: "リンク"
        case let .heading(level): level == 0 ? "本文" : "見出し \(level)"
        case .quote: "引用"
        case .unorderedList: "箇条書き"
        case .orderedList: "番号付きリスト"
        case .taskList: "タスクリスト"
        case .toggleTaskCompletion: "タスクの完了を切り替え"
        case let .codeBlock(language): language.map { "\($0.title) コードブロック" } ?? "言語なし"
        case .horizontalRule: "区切り線"
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
        case .heading: "number"
        case .quote: "text.quote"
        case .unorderedList: "list.bullet"
        case .orderedList: "list.number"
        case .taskList: "checklist"
        case .toggleTaskCompletion: "checkmark.square"
        case .codeBlock: "chevron.left.forwardslash.chevron.right"
        case .horizontalRule: "minus"
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
        case let .heading(level): (KeyEquivalent(Character(String(level))), [.command, .option])
        case .quote: (">", [.command, .shift])
        case .unorderedList: ("8", [.command, .shift])
        case .orderedList: ("7", [.command, .shift])
        case .taskList: ("9", [.command, .shift])
        case .toggleTaskCompletion: ("t", [.command, .option])
        case let .codeBlock(language): language == nil ? ("`", [.command, .option]) : nil
        case .horizontalRule: nil
        case .find: ("f", .command)
        }
    }

    @MainActor
    func canExecute(in model: MarkdownEditorModel?) -> Bool {
        model?.canExecuteCommand ?? false
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
        case let .heading(level): model.apply(.heading(level: level))
        case .quote: model.apply(.quote)
        case .unorderedList: model.apply(.unorderedList)
        case .orderedList: model.apply(.orderedList)
        case .taskList: model.apply(.taskList)
        case .toggleTaskCompletion: model.toggleTaskCompletion()
        case let .codeBlock(language): model.apply(.codeBlock(language: language))
        case .horizontalRule: model.apply(.horizontalRule)
        case .find: model.showFindBar()
        }
    }
}
