import Foundation

/// iPhone版のエディタのフォント。iOSに同梱されているフォントから、コードと日本語の文章に
/// 向くものを選んでいる（docs/editor-font-selection.md）。raw value を `storageKey` に保存する。
/// 以前の版の保存値はないが、保存後に raw value を変えると選択が既定に戻るため変えない。
enum MobileEditorFont: String, CaseIterable, Sendable {
    case monospacedSystem
    case menlo
    case courierNew
    case system
    case hiraginoSans
    case serifSystem
    case hiraginoMincho
    case georgia
    case roundedSystem
    case hiraginoMaruGothic

    static let `default` = MobileEditorFont.monospacedSystem
    static let storageKey = "mobile.editorFont"

    /// 設定画面で選択肢をまとめる分類。
    enum Category: CaseIterable, Sendable {
        case monospaced
        case gothic
        case serif
        case rounded
    }

    /// システムフォント（SF）の書体の種類。`UIFontDescriptor.SystemDesign` に対応する。
    enum SystemDesign: Sendable {
        case standard
        case monospaced
        case serif
        case rounded
    }

    /// フォントの取り出し方。
    enum Face: Equatable, Sendable {
        case system(SystemDesign)
        /// iOSに同梱されているフォントのPostScript名。
        case named(String)
    }

    var category: Category {
        switch self {
        case .monospacedSystem, .menlo, .courierNew: .monospaced
        case .system, .hiraginoSans: .gothic
        case .serifSystem, .hiraginoMincho, .georgia: .serif
        case .roundedSystem, .hiraginoMaruGothic: .rounded
        }
    }

    var face: Face {
        switch self {
        case .monospacedSystem: .system(.monospaced)
        case .menlo: .named("Menlo-Regular")
        case .courierNew: .named("CourierNewPSMT")
        case .system: .system(.standard)
        case .hiraginoSans: .named("HiraginoSans-W3")
        case .serifSystem: .system(.serif)
        case .hiraginoMincho: .named("HiraMinProN-W3")
        case .georgia: .named("Georgia")
        case .roundedSystem: .system(.rounded)
        case .hiraginoMaruGothic: .named("HiraMaruProN-W4")
        }
    }

    /// 日本語の字形に使うフォントのPostScript名。欧文だけのフォントで日本語を書くと、iOSは
    /// ヒラギノ角ゴシックで表示する。明朝・丸ゴシックの欧文フォントでは、日本語も同じ分類の
    /// ヒラギノで表示して、1行の中で字形の印象がそろうようにする。`nil` はiOSの既定に任せる。
    var japaneseFallback: String? {
        switch self {
        case .serifSystem, .georgia: "HiraMinProN-W3"
        case .roundedSystem: "HiraMaruProN-W4"
        default: nil
        }
    }

    /// 保存値を読む。知らない値（以降の版が保存した選択肢など）は既定にする。
    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .default
    }

    static func options(in category: Category) -> [MobileEditorFont] {
        allCases.filter { $0.category == category }
    }
}
