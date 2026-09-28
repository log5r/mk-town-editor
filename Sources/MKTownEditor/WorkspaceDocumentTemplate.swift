import Foundation

enum WorkspaceDocumentTemplate: String, CaseIterable, Identifiable {
    case blank
    case starter
    case meetingNotes
    case article

    var id: Self { self }

    var title: String {
        switch self {
        case .blank: String(localized: "空の書類")
        case .starter: String(localized: "はじめに")
        case .meetingNotes: String(localized: "会議メモ")
        case .article: String(localized: "記事")
        }
    }

    var text: String {
        switch self {
        case .blank: ""
        case .starter: String(localized: "# 無題\n\nMarkdown で書き始めましょう。")
        case .meetingNotes: String(localized: "# 会議メモ\n\n## 日時・参加者\n\n## 議題\n\n## 決定事項\n\n## 次のアクション\n")
        case .article: String(localized: "# タイトル\n\n## 概要\n\n## 本文\n\n## まとめ\n")
        }
    }
}
