import SwiftUI

enum EditorCommand: Hashable {
    case bold
    case italic
    case inlineCode
    case link
    case heading(level: Int)
    case quote
    case unorderedList
    case find

    static let toolbar: [Self] = [.bold, .italic, .link]
    static let context: [Self] = [.bold, .italic, .inlineCode, .link, .quote, .unorderedList]

    var title: String {
        switch self {
        case .bold: "太字"
        case .italic: "斜体"
        case .inlineCode: "インラインコード"
        case .link: "リンク"
        case let .heading(level): level == 0 ? "本文" : "見出し \(level)"
        case .quote: "引用"
        case .unorderedList: "箇条書き"
        case .find: "検索…"
        }
    }

    var symbolName: String {
        switch self {
        case .bold: "bold"
        case .italic: "italic"
        case .inlineCode: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .heading: "number"
        case .quote: "text.quote"
        case .unorderedList: "list.bullet"
        case .find: "magnifyingglass"
        }
    }

    var shortcut: (key: KeyEquivalent, modifiers: EventModifiers) {
        switch self {
        case .bold: ("b", .command)
        case .italic: ("i", .command)
        case .inlineCode: ("`", .command)
        case .link: ("k", .command)
        case let .heading(level): (KeyEquivalent(Character(String(level))), [.command, .option])
        case .quote: (">", [.command, .shift])
        case .unorderedList: ("8", [.command, .shift])
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
        case .inlineCode: model.apply(.inlineCode)
        case .link: model.apply(.link)
        case let .heading(level): model.apply(.heading(level: level))
        case .quote: model.apply(.quote)
        case .unorderedList: model.apply(.unorderedList)
        case .find: model.showFindBar()
        }
    }
}
