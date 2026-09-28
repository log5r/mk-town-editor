import Foundation

enum WorkspaceDocumentTemplate: String, CaseIterable, Identifiable {
    case blank
    case starter
    case meetingNotes
    case article

    var id: Self { self }

    var title: String {
        switch self {
        case .blank: "空の書類"
        case .starter: "はじめに"
        case .meetingNotes: "会議メモ"
        case .article: "記事"
        }
    }

    var text: String {
        switch self {
        case .blank: ""
        case .starter: "# 無題\n\nMarkdown で書き始めましょう。"
        case .meetingNotes: "# 会議メモ\n\n## 日時・参加者\n\n## 議題\n\n## 決定事項\n\n## 次のアクション\n"
        case .article: "# タイトル\n\n## 概要\n\n## 本文\n\n## まとめ\n"
        }
    }
}
