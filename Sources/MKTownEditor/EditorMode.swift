import Foundation

enum EditorMode: String, CaseIterable, Identifiable, Codable {
    case editor
    case split
    case preview

    var id: Self { self }

    var label: String {
        switch self {
        case .editor: String(localized: "編集")
        case .split: String(localized: "分割")
        case .preview: String(localized: "プレビュー")
        }
    }

    var symbolName: String {
        switch self {
        case .editor: "square.and.pencil"
        case .split: "rectangle.split.2x1"
        case .preview: "eye"
        }
    }
}
