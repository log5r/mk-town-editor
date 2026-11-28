import AppKit
import Combine
import Foundation
import SwiftUI

/// 標準装備のエディタのフォント。`AppEditorSettings.fontChoice` に raw value で保存する。
/// 以前の版も同じ値を読むため、ケースを消したり raw value を変えたりしない。
/// インストール済みの任意のフォントは `EditorFont.family` で表し、別の項目に保存する（docs/editor-font-selection.md）。
enum EditorFontChoice: String, Codable, CaseIterable {
    case monospacedSystem
    case system
    case menlo

    var title: String {
        switch self {
        case .monospacedSystem: String(localized: "システム等幅")
        case .system: String(localized: "システム")
        case .menlo: "Menlo"
        }
    }

    @MainActor
    func font(size: CGFloat) -> NSFont {
        switch self {
        case .monospacedSystem: .monospacedSystemFont(ofSize: size, weight: .regular)
        case .system: .systemFont(ofSize: size)
        case .menlo: NSFont(name: "Menlo-Regular", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }
}

/// エディタの本文に使うフォント。標準装備の選択肢か、Macにインストールされているフォントファミリー。
enum EditorFont: Hashable, Sendable {
    case builtIn(EditorFontChoice)
    /// フォントファミリー名（`NSFontManager.availableFontFamilies` の値。表示名ではない）。
    case family(String)

    static let `default` = EditorFont.builtIn(.monospacedSystem)

    /// インストール済みのフォントファミリーを使うか。フォントの追加・削除で表示が変わるのはこの場合だけ。
    var isFamily: Bool {
        if case .family = self { return true }
        return false
    }

    /// フォントファミリーがこのMacにあるか。標準装備の選択肢は常にある。
    @MainActor
    var isAvailable: Bool {
        switch self {
        case .builtIn: true
        case .family(let name): Self.familyIsInstalled(name)
        }
    }

    /// 設定画面に出す名前。フォントファミリーは表示言語での名前（例: ヒラギノ角ゴシック）。
    @MainActor
    var title: String {
        switch self {
        case .builtIn(let choice): choice.title
        case .family(let name): NSFontManager.shared.localizedName(forFamily: name, face: nil)
        }
    }

    /// 本文のフォント。フォントファミリーが見つからないとき（削除した、フォント管理アプリで無効にしたなど）は
    /// 既定のフォント（システム等幅）にする。設定の値は消さないので、フォントを戻すとまた使われる。
    /// `resolver` はテストでフォントの追加・削除を再現するときだけ差し替える。
    @MainActor
    func font(size: CGFloat, resolver: EditorFontResolver = .system) -> NSFont {
        switch self {
        case .builtIn(let choice):
            choice.font(size: size)
        case .family(let name):
            resolver.familyFont(name, size) ?? Self.default.font(size: size)
        }
    }

    @MainActor
    private static func familyIsInstalled(_ name: String) -> Bool {
        !name.isEmpty && !(NSFontManager.shared.availableMembers(ofFontFamily: name) ?? []).isEmpty
    }
}

/// フォントファミリー名から本文の書体を取り出す処理。見つからなければ `nil`。
/// フォントのインストールと削除はテストで行えないため、テストではこれを差し替えて再現する。
struct EditorFontResolver {
    var familyFont: @MainActor (_ family: String, _ size: CGFloat) -> NSFont?

    /// このMacにインストールされているフォントから取り出す。
    static var system: EditorFontResolver {
        EditorFontResolver { name, size in
            guard !name.isEmpty else { return nil }
            // weight 5 は標準の太さ。ファミリーにない場合は近い太さの書体を返す。
            if let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) {
                return font
            }
            // 斜体だけのファミリーなどで標準の書体が見つからないときは、ファミリーの最初の書体を使う。
            if let first = NSFontManager.shared.availableMembers(ofFontFamily: name)?.first?.first as? String {
                return NSFont(name: first, size: size)
            }
            return nil
        }
    }
}

/// 設定画面のフォントの選択肢。インストール済みのファミリーを等幅とそれ以外に分け、
/// 一覧にない選択中のファミリー（見つからないフォント）を別に持つ。
struct EditorFontOptions: Equatable {
    /// フォントの見本。英数字の見分けやすさ（0とO、1とlとI）、括弧、日本語の字形を並べる。
    static let sampleText = "AaBbCc 0O 1lI {}[] — あア漢字"

    var monospaced: [EditorFontFamily]
    var proportional: [EditorFontFamily]
    /// 選択中だが一覧にないフォントファミリー。ポップアップボタンを空欄にしないため項目として出す。
    var unlistedFamily: String?
    /// `unlistedFamily` が見つからないフォントか。一覧を読み込む前は判断しない。
    var isMissing: Bool

    init(installed: [EditorFontFamily], selected: EditorFont) {
        monospaced = installed.filter(\.isMonospaced)
        proportional = installed.filter { !$0.isMonospaced }
        if case .family(let name) = selected, !installed.contains(where: { $0.name == name }) {
            unlistedFamily = name
            isMissing = !installed.isEmpty
        } else {
            unlistedFamily = nil
            isMissing = false
        }
    }
}

/// 設定画面でエディタのフォントの候補に出す、インストール済みのフォントファミリー。
struct EditorFontFamily: Hashable, Sendable {
    /// 保存に使うファミリー名。
    var name: String
    /// 表示言語でのファミリー名。
    var displayName: String
    /// 等幅の書体か。設定画面で等幅とそれ以外を分けて並べる。
    var isMonospaced: Bool

    /// インストール済みのフォントファミリーを表示名の順に返す。
    /// 書体を作らずにフォントの記述子から属性を読むので、数百ファミリーあっても軽い。
    /// 名前が `.` で始まるシステム内部用のファミリーは除く。
    static func installed() -> [EditorFontFamily] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var families: [String: EditorFontFamily] = [:]
        for descriptor in descriptors {
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  !name.isEmpty, !name.hasPrefix(".") else { continue }
            let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any]
            let symbolic = (traits?[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let monospaced = symbolic & CTFontSymbolicTraits.traitMonoSpace.rawValue != 0
            if var existing = families[name] {
                // ファミリーのどれかの書体が等幅なら等幅として扱う。
                if monospaced, !existing.isMonospaced {
                    existing.isMonospaced = true
                    families[name] = existing
                }
                continue
            }
            let displayName = CTFontDescriptorCopyLocalizedAttribute(descriptor, kCTFontFamilyNameAttribute, nil)
                as? String ?? name
            families[name] = EditorFontFamily(name: name, displayName: displayName, isMonospaced: monospaced)
        }
        return families.values.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }
}

enum ProofingLanguage: String, Codable, CaseIterable {
    case automatic
    case english
    case japanese

    var title: String {
        switch self {
        case .automatic: String(localized: "自動判定")
        case .english: String(localized: "英語")
        case .japanese: String(localized: "日本語")
        }
    }

    var spellCheckerIdentifier: String? {
        switch self {
        case .automatic: nil
        case .english: "en"
        case .japanese: "ja"
        }
    }
}

enum MarkdownDialect: String, Codable, CaseIterable, Sendable {
    case extended
    case basic

    var title: String {
        switch self {
        case .extended: String(localized: "拡張（表・脚注・フロントマター）")
        case .basic: String(localized: "基本（表・脚注・フロントマターなし）")
        }
    }
}

enum PreviewTheme: Codable, Hashable, Sendable {
    /// プレビューではmacOSの外観に追従する配色。編集画面では選べず、以前の版の保存値は「紺色」として読む。
    case system
    /// 編集画面の既定の配色。GitHub風（ダーク）を明るくした文字色を紺の背景に載せる。プレビューの選択肢には出さない。
    case navy
    case paper
    case preset(PreviewThemePreset)
    case extensionTheme(DeclarativeExtension.Theme)

    /// 標準装備の配色。編集画面とプレビューで選べるものは `ThemeTarget.basicThemes` が決める。
    static let allCases: [Self] = [.system, .navy, .paper] + PreviewThemePreset.allCases.map(Self.preset)

    /// 「紺色」の背景。
    static let navyBackground = "#283264"
    /// 「紺色」の着色した文字（見出し・リンク・記号・行番号・コードの字句）に求める、背景とのコントラスト比（WCAG AAA）。
    /// 紺の背景は彩度があり、4.5:1では青や赤の文字が沈んで見えるため、ほかのテーマより高くする（Issue #99）。
    static let navyMinimumContrast = 7.0
    /// 「紺色」の色。GitHub風（ダーク）の文字色を紺の背景に載せ、紺の背景で `navyMinimumContrast` に
    /// 届かない色は、同じ色相の明るい色に置き換える。背景は配色のコンセプトなので変えない。
    /// 背景が暗い色で固定のため、macOSの外観がライトでもダークの外観で表示する。
    static let navyDefinition: DeclarativeExtension.Theme = {
        var colors = PreviewThemePreset.githubDark.theme
        colors.background = navyBackground
        // 見出しとリンクは明るい水色にする。
        colors.link = "#7ADCFF"
        colors.syntax?.merge(["keyword": "#FFB4AC", "type": "#DABAFF", "comment": "#C0C6D0",
                              "number": "#92CDFF", "variable": "#FFB76E"]) { _, bright in bright }
        return colors
    }()

    /// 知らないテーマ名や読めない色の定義は、投げずに「システム」として読む。設定はJSON1つを丸ごと
    /// デコードするため、1項目の失敗で全設定が既定に戻ってしまう（Issue #107）。「システム」は
    /// プレビューの既定で、編集画面では既定の「紺色」として扱う（`editorColors`）。
    /// 以前の版が書いた `"navy"` も読む。
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let name = try? value.decode(String.self) {
            switch name {
            case "system": self = .system
            case "navy": self = .navy
            case "paper": self = .paper
            default: self = PreviewThemePreset(rawValue: name).map(Self.preset) ?? .system
            }
        } else if let theme = try? value.decode(DeclarativeExtension.Theme.self) {
            self = .extensionTheme(theme)
        } else {
            self = .system
        }
    }

    /// 「紺色」は `"system"` として書く。PR #98 より前の版は `"navy"` を知らず、設定全体の
    /// デコードに失敗するため。それらの版の編集画面の「システム」は紺の背景の配色で、この版も
    /// 編集画面の `"system"` を「紺色」として読む（`AppEditorSettings.restoreNavyEditorThemes`）ため、
    /// 編集画面では失うものがない。「紺色」はプレビューでは選べない（docs/settings-backward-compatibility.md）。
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .system, .navy: try value.encode("system")
        case .paper: try value.encode("paper")
        case .preset(let preset): try value.encode(preset.rawValue)
        case .extensionTheme(let theme): try value.encode(theme)
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "システム")
        case .navy: String(localized: "紺色")
        case .paper: String(localized: "紙色")
        case .preset(let preset): preset.title
        case .extensionTheme(let theme): theme.name
        }
    }

    /// 色を16進数で定義するテーマ（紺色、標準装備の配色、JSON拡張）。システムと紙色は `nil`。
    var definition: DeclarativeExtension.Theme? {
        switch self {
        case .system, .paper: nil
        case .navy: Self.navyDefinition
        case .preset(let preset): preset.theme
        case .extensionTheme(let theme): theme
        }
    }

    var background: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.98, green: 0.965, blue: 0.93, alpha: 1)
        case .navy, .preset, .extensionTheme: definition?.color(\.background)
        }
    }
    var bodyColor: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.18, green: 0.16, blue: 0.13, alpha: 1)
        case .navy, .preset, .extensionTheme: definition?.color(\.body)
        }
    }
    var headingColor: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.31, green: 0.19, blue: 0.11, alpha: 1)
        case .navy, .preset, .extensionTheme: definition?.color(\.heading)
        }
    }
    var codeColor: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.34, green: 0.18, blue: 0.10, alpha: 1)
        case .navy, .preset, .extensionTheme: definition?.color(\.code)
        }
    }
    var linkColor: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.10, green: 0.22, blue: 0.38, alpha: 1)
        case .navy, .preset, .extensionTheme: definition?.color(\.link)
        }
    }
    var codeBackground: NSColor? {
        switch self {
        case .system: nil
        case .paper: NSColor(srgbRed: 0.91, green: 0.87, blue: 0.79, alpha: 1)
        case .navy, .preset, .extensionTheme: definition?.color(\.codeBackground)
        }
    }
    var colorScheme: ColorScheme? {
        guard let color = background?.usingColorSpace(.sRGB) else { return nil }
        let luminance = 0.2126 * color.redComponent +
            0.7152 * color.greenComponent + 0.0722 * color.blueComponent
        return luminance < 0.5 ? .dark : .light
    }
}

enum AttachmentDirectory: String, Codable, CaseIterable, Sendable {
    case assets
    case images

    var title: String { rawValue }
}

enum EditorIndentationStyle: String, Codable, CaseIterable, Sendable {
    case spaces
    case tabs

    init(from decoder: Decoder) throws {
        let storedValue = try? decoder.singleValueContainer().decode(String.self)
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .spaces
    }

    var title: String {
        switch self {
        case .spaces: String(localized: "スペース")
        case .tabs: String(localized: "タブ")
        }
    }
}

struct EditorWhitespaceEditingOptions: Equatable, Sendable {
    var indentationStyle: EditorIndentationStyle = .spaces
    var detectsIndentation = false
    var trimsTrailingWhitespaceOnSave = false
    var trimsWhitespaceOnlyLines = false
}

struct EditorTextTransformationOptions: Codable, Equatable, Sendable {
    var convertsAlphanumerics = true
    var convertsSymbols = true
    var convertsKana = true
    var preservesCodeAndURLs = true
}

struct EditorHighlightSettings: Codable, Equatable, Sendable {
    static let wordDelayRange = 0.10...2.00
    static let defaultWordDelay = 0.35

    var currentLine: Bool
    var matchingBrackets: Bool
    var selectedWord: Bool
    var wordDelay: Double {
        didSet { wordDelay = Self.normalizedDelay(wordDelay) }
    }

    init(currentLine: Bool = false, matchingBrackets: Bool = false, selectedWord: Bool = false,
         wordDelay: Double = Self.defaultWordDelay) {
        self.currentLine = currentLine
        self.matchingBrackets = matchingBrackets
        self.selectedWord = selectedWord
        self.wordDelay = Self.normalizedDelay(wordDelay)
    }

    enum CodingKeys: CodingKey { case currentLine, matchingBrackets, selectedWord, wordDelay }

    init(from decoder: Decoder) {
        let values = try? decoder.container(keyedBy: CodingKeys.self)
        self.init(currentLine: (try? values?.decode(Bool.self, forKey: .currentLine)) ?? false,
                  matchingBrackets: (try? values?.decode(Bool.self, forKey: .matchingBrackets)) ?? false,
                  selectedWord: (try? values?.decode(Bool.self, forKey: .selectedWord)) ?? false,
                  wordDelay: (try? values?.decode(Double.self, forKey: .wordDelay)) ?? Self.defaultWordDelay)
    }

    private static func normalizedDelay(_ delay: Double) -> Double {
        guard delay.isFinite else { return defaultWordDelay }
        return min(max(delay, wordDelayRange.lowerBound), wordDelayRange.upperBound)
    }
}

struct EditorProofingSettings: Codable, Equatable {
    var language: ProofingLanguage = .automatic
    var checksSpelling = true
    var correctsSpelling = true
}

struct EditorSnippet: Codable, Equatable, Identifiable {
    var id = UUID()
    var trigger: String
    var template: String
}

struct EditorTextStyle: Equatable {
    var font: EditorFont = .default
    var fontSize: Double = 13
    var lineSpacing: Double = 3
    var horizontalMargin: Double = 18
    var verticalMargin: Double = 18
    var tabWidth: Int = 4

    @MainActor
    func apply(to textView: NSTextView) {
        let editor = textView as? EditorTextView
        let font = self.font.font(size: CGFloat(fontSize), resolver: editor?.fontResolver ?? .system)
        // font や余白の設定中に同期レイアウトが起きても、新しい本文フォントを基準にする。
        editor?.prepareToApplyTextStyle(self, font: font)
        textView.font = font
        textView.textContainerInset = NSSize(width: horizontalMargin, height: verticalMargin)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(lineSpacing)
        paragraph.tabStops = []
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(tabWidth)
        textView.defaultParagraphStyle = paragraph
        var typing = textView.typingAttributes
        typing[.paragraphStyle] = paragraph
        textView.typingAttributes = typing
    }
}

struct EditorLayoutOptions: Equatable {
    var wrapsLines = true
    var showsLineNumbers = true
    var listIndentWidth = 2
    var codeIndentWidth = 4

    @MainActor
    func apply(to textView: NSTextView, in scrollView: NSScrollView) {
        scrollView.rulersVisible = showsLineNumbers
        scrollView.hasHorizontalScroller = !wrapsLines
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = wrapsLines ? [.width] : []
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapsLines ? 0 : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        synchronizeWidth(of: textView, in: scrollView)
    }

    @MainActor
    func synchronizeWidth(of textView: NSTextView, in scrollView: NSScrollView) {
        let viewportWidth = scrollView.contentSize.width
        let requiredWidth: CGFloat
        if wrapsLines {
            requiredWidth = viewportWidth
        } else if let layoutManager = textView.layoutManager,
                  let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            requiredWidth = max(viewportWidth, ceil(layoutManager.usedRect(for: container).maxX
                                                    + textView.textContainerInset.width * 2))
        } else {
            requiredWidth = viewportWidth
        }
        if abs(textView.frame.width - requiredWidth) > 0.5 {
            textView.frame.size.width = requiredWidth
        }
    }
}

enum DocumentStatusField: String, CaseIterable, Sendable {
    case characters, words, lines, position, selectionLength, encoding, lineEnding, fileSize

    var title: String {
        switch self {
        case .characters: String(localized: "文字数")
        case .words: String(localized: "語数")
        case .lines: String(localized: "行数")
        case .position: String(localized: "現在の行と桁")
        case .selectionLength: String(localized: "選択範囲の長さ")
        case .encoding: String(localized: "文字コード")
        case .lineEnding: String(localized: "改行コード")
        case .fileSize: String(localized: "ファイルサイズ")
        }
    }
}

extension DocumentCountUnit {
    var title: String {
        switch self {
        case .grapheme: String(localized: "書記素クラスタ（見た目の1文字）")
        case .unicodeScalar: String(localized: "Unicodeスカラー")
        case .utf16: String(localized: "UTF-16コード単位")
        case .bytes: String(localized: "バイト数")
        }
    }
}

struct DocumentStatisticsPreferences: Codable, Equatable, Sendable {
    var count = DocumentCountOptions()
    var statusFields: Set<DocumentStatusField> = [.characters, .words, .lines, .encoding]
}

extension DocumentStatisticsPreferences {
    private enum CodingKeys: String, CodingKey { case count, statusFields }

    init(from decoder: Decoder) throws {
        self.init()
        guard let values = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        count = (try? values.decode(DocumentCountOptions.self, forKey: .count)) ?? count
        if let names = try? values.decode([String].self, forKey: .statusFields) {
            statusFields = Set(names.compactMap(DocumentStatusField.init(rawValue:)))
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(count, forKey: .count)
        // Stable ordering lets the settings store skip identical writes.
        try values.encode(DocumentStatusField.allCases.filter(statusFields.contains).map(\.rawValue),
                          forKey: .statusFields)
    }
}

struct AppEditorSettings: Codable, Equatable {
    var defaultMode: EditorMode = .split
    var fontSize: Double = 13
    var lineSpacing: Double = 3
    var wrapsLines = true
    var imageImportMode: ImageImportMode?
    /// 標準装備のフォント。`fontFamily` があればそちらを使う。読み書きは `editorFont` を通す。
    var fontChoice: EditorFontChoice?
    /// インストール済みのフォントから選んだフォントファミリー名。この項目を知らない以前の版は
    /// 無視して `fontChoice` を使うので、以前の版に戻しても設定全体が読めなくなることはない。
    var fontFamily: String?
    var horizontalMargin: Double?
    var verticalMargin: Double?
    var tabWidth: Int?
    var listIndentWidth: Int?
    var codeIndentWidth: Int?
    var indentationStyle: EditorIndentationStyle?
    var detectsIndentation: Bool?
    var trimsTrailingWhitespaceOnSave: Bool?
    var trimsWhitespaceOnlyLines: Bool?
    var textTransformation: EditorTextTransformationOptions?
    var tableAddsRowOnTab: Bool?
    var editorZoom: Double?
    var previewZoom: Double?
    var wordCountMode: WordCountMode?
    var statistics: DocumentStatisticsPreferences?
    var readingEstimate: ReadingEstimateSettings?
    var disabledLintRules: Set<MarkdownLintRule>?
    var proofing: EditorProofingSettings?
    var showsFrontMatterInPreview: Bool?
    var formatsFrontMatterInPreview: Bool?
    var preservesSoftLineBreaksInPreview: Bool?
    var snippets: [EditorSnippet]?
    var loadsRemoteImages: Bool?
    var loadsExternalLinkPreviews: Bool?
    var showsMinimap: Bool?
    var usesInlineLivePresentation: Bool?
    var usesTypewriterMode: Bool?
    var highlights: EditorHighlightSettings?
    var terminologyEntries: [TerminologyEntry]?
    var terminologyOptions: TerminologyOptions?
    var attachmentDirectory: AttachmentDirectory?
    var markdownDialect: MarkdownDialect?
    /// プレビューの配色。外観に合わせて切り替えないときに使う。未設定は「システム」。
    var previewTheme: PreviewTheme?
    /// 編集画面の配色。外観に合わせて切り替えないときに使う。未設定は既定の「紺色」。
    /// 以前の版で保存した「システム」は「紺色」として読む（`theme(for:slot:)`）。
    var editorTheme: PreviewTheme?
    /// macOSの外観（ライト・ダーク）に合わせて編集画面の配色を切り替えるか。未設定はオフ。
    var editorThemeFollowsAppearance: Bool?
    /// 外観に合わせて切り替えるときの、ライト外観の編集画面の配色。未設定は `ThemeTarget.editor` の既定。
    var editorLightTheme: PreviewTheme?
    /// 外観に合わせて切り替えるときの、ダーク外観の編集画面の配色。
    var editorDarkTheme: PreviewTheme?
    /// macOSの外観に合わせてプレビューの配色を切り替えるか。未設定はオフ。
    var previewThemeFollowsAppearance: Bool?
    /// 外観に合わせて切り替えるときの、ライト外観のプレビューの配色。
    var previewLightTheme: PreviewTheme?
    /// 外観に合わせて切り替えるときの、ダーク外観のプレビューの配色。
    var previewDarkTheme: PreviewTheme?
    var extensionPackages: [DeclarativeExtension]?
    var previewBodyWidth: Int?
    var showsInvisibleCharacters: Bool?
    var showsIndentGuides: Bool?
    var showsLineNumbers: Bool?
    var shortcutOverrides: [String: ShortcutChord]?
    /// Missing in settings saved before the option existed; those read as `.default`.
    var documentOpeningMode: DocumentOpeningMode?
    var asksAboutMixedNewlines: Bool?

    var effectiveDocumentOpeningMode: DocumentOpeningMode { documentOpeningMode ?? .default }

    var textTransformationOptions: EditorTextTransformationOptions {
        get { textTransformation ?? EditorTextTransformationOptions() }
        set { textTransformation = newValue == EditorTextTransformationOptions() ? nil : newValue }
    }

    var highlightOptions: EditorHighlightSettings {
        get { highlights ?? EditorHighlightSettings() }
        set { highlights = newValue == EditorHighlightSettings() ? nil : newValue }
    }

    var statisticsPreferences: DocumentStatisticsPreferences {
        get { statistics ?? DocumentStatisticsPreferences() }
        set { statistics = newValue == DocumentStatisticsPreferences() ? nil : newValue }
    }

    /// エディタのフォント。フォントファミリーを選ぶと `fontFamily` だけを書き、`fontChoice` は
    /// 以前の版が使う値として残す。標準装備の選択肢を選ぶと `fontFamily` を消す。
    var editorFont: EditorFont {
        get {
            if let fontFamily, !fontFamily.isEmpty { return .family(fontFamily) }
            return .builtIn(fontChoice ?? .monospacedSystem)
        }
        set {
            switch newValue {
            case .builtIn(let choice):
                fontChoice = choice
                fontFamily = nil
            case .family(let name):
                fontFamily = name.isEmpty ? nil : name
            }
        }
    }

    var effectiveSnippets: [EditorSnippet] {
        (snippets ?? []) + (extensionPackages ?? []).flatMap { package in
            package.snippets.map { EditorSnippet(id: $0.id, trigger: $0.trigger, template: $0.template) }
        }
    }
}

/// macOSの外観の明暗。配色を外観に合わせて切り替えるときに使う。
enum InterfaceAppearance: Sendable {
    case light
    case dark

    init(_ appearance: NSAppearance) {
        self = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

/// 配色を保存する項目。外観に合わせないときの固定の配色と、合わせるときのライト用・ダーク用がある。
enum ThemeSlot: CaseIterable, Sendable {
    case fixed
    case light
    case dark
}

/// 配色を選ぶ対象（編集画面かプレビュー）。保存先の項目と既定の配色、選択肢をまとめる。
enum ThemeTarget: CaseIterable, Sendable {
    case editor
    case preview

    var followsAppearanceKeyPath: WritableKeyPath<AppEditorSettings, Bool?> {
        switch self {
        case .editor: \.editorThemeFollowsAppearance
        case .preview: \.previewThemeFollowsAppearance
        }
    }

    func keyPath(for slot: ThemeSlot) -> WritableKeyPath<AppEditorSettings, PreviewTheme?> {
        switch (self, slot) {
        case (.editor, .fixed): \.editorTheme
        case (.editor, .light): \.editorLightTheme
        case (.editor, .dark): \.editorDarkTheme
        case (.preview, .fixed): \.previewTheme
        case (.preview, .light): \.previewLightTheme
        case (.preview, .dark): \.previewDarkTheme
        }
    }

    /// 項目が未設定のときの配色。
    func defaultTheme(for slot: ThemeSlot) -> PreviewTheme {
        switch (self, slot) {
        case (.editor, .fixed): EditorThemePalette.defaultTheme
        case (.editor, .light), (.preview, .light): .preset(.githubLight)
        case (.editor, .dark): .navy
        case (.preview, .fixed): .system
        case (.preview, .dark): .preset(.githubDark)
        }
    }

    /// 選択肢の先頭に並べる基本の配色。「システム」はプレビューだけ、「紺色」は編集画面だけに出す。
    /// 「紺色」は編集画面のための配色で、プレビューには出さない。
    var basicThemes: [PreviewTheme] {
        switch self {
        case .editor: [.navy, .paper]
        case .preview: [.system, .paper]
        }
    }

    /// 保存値を対象で使える配色にする。編集画面には「システム」がないため「紺色」にする。
    func normalized(_ theme: PreviewTheme) -> PreviewTheme {
        self == .editor ? theme.editorColors : theme
    }
}

extension AppEditorSettings {
    /// 編集画面の項目に読んだ `"system"` を「紺色」に戻す。「紺色」は以前の版が読めるよう `"system"` で
    /// 書くため（`PreviewTheme.encode(to:)`）、読み込んだ後にこれを通すと、選んだ値がそのまま戻る。
    /// 書き出すと同じバイト列になるので、保存データは変わらない。
    mutating func restoreNavyEditorThemes() {
        for slot in ThemeSlot.allCases {
            let keyPath = ThemeTarget.editor.keyPath(for: slot)
            if self[keyPath: keyPath] == .system { self[keyPath: keyPath] = .navy }
        }
    }

    func followsAppearance(for target: ThemeTarget) -> Bool {
        self[keyPath: target.followsAppearanceKeyPath] ?? false
    }

    /// `appearance` のときに使う項目。外観に合わせないなら固定の配色の項目。
    func themeSlot(for target: ThemeTarget, appearance: InterfaceAppearance) -> ThemeSlot {
        guard followsAppearance(for: target) else { return .fixed }
        return appearance == .dark ? .dark : .light
    }

    /// 項目に保存した配色。未設定なら既定の配色を返す。
    func theme(for target: ThemeTarget, slot: ThemeSlot) -> PreviewTheme {
        target.normalized(self[keyPath: target.keyPath(for: slot)] ?? target.defaultTheme(for: slot))
    }

    /// 設定と外観から決まる、対象で使う配色。
    func theme(for target: ThemeTarget, appearance: InterfaceAppearance) -> PreviewTheme {
        theme(for: target, slot: themeSlot(for: target, appearance: appearance))
    }

    /// `appearance` のときに使う項目に `theme` を保存する。外観に合わせるなら現在の外観の側、合わせないなら固定の配色を変える。
    mutating func selectTheme(_ theme: PreviewTheme, for target: ThemeTarget, appearance: InterfaceAppearance) {
        self[keyPath: target.keyPath(for: themeSlot(for: target, appearance: appearance))] = theme
    }
}

enum EditorZoomSurface: CaseIterable {
    case editor, preview

    var title: String { self == .editor ? String(localized: "編集") : String(localized: "プレビュー") }
}

enum EditorSplitOrientation: String, Codable, CaseIterable {
    case sideBySide
    case stacked

    var title: String { self == .sideBySide ? String(localized: "左右") : String(localized: "上下") }

    /// Earlier versions stored the Japanese titles as raw values.
    init?(storedValue: String) {
        switch storedValue {
        case "左右": self = .sideBySide
        case "上下": self = .stacked
        default: self.init(rawValue: storedValue)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let orientation = Self(storedValue: value) else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Unknown split orientation \(value)")
        }
        self = orientation
    }
}

struct FocusModeState {
    private(set) var savedSidebarVisibility: NavigationSplitViewVisibility?
    var isActive: Bool { savedSidebarVisibility != nil }

    mutating func toggle(sidebarVisibility: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility {
        if let savedSidebarVisibility {
            self.savedSidebarVisibility = nil
            return savedSidebarVisibility
        }
        savedSidebarVisibility = sidebarVisibility
        return .detailOnly
    }
}

enum EditorSplitSizing {
    static func editorExtent(total: CGFloat, ratio: Double, minimum: CGFloat) -> CGFloat {
        let available = max(1, total - 8)
        let effectiveMinimum = min(minimum, available / 2)
        return max(effectiveMinimum,
                   min(available - effectiveMinimum, available * ratio))
    }

    /// The ratio after dragging the divider `delta` points from where it was at `start`.
    /// `editorTrailing` is true when the editor follows the preview, so dragging toward the
    /// trailing edge shrinks it.
    static func draggedRatio(from start: Double, delta: CGFloat, total: CGFloat,
                             minimum: CGFloat, editorTrailing: Bool) -> Double {
        let available = max(1, total - SplitDividerHandle.thickness)
        let effectiveMinimum = Double(min(minimum, available / 2) / available)
        let proposed = start + Double((editorTrailing ? -delta : delta) / available)
        return max(effectiveMinimum, min(1 - effectiveMinimum, proposed))
    }

    /// Keyboard and VoiceOver adjustments move the divider in 5% steps within 20–80%.
    static func adjustedRatio(_ ratio: Double, increment: Bool) -> Double {
        increment ? min(0.8, ratio + 0.05) : max(0.2, ratio - 0.05)
    }
}

struct FolderEditorSettings: Codable, Equatable {
    var defaultMode: EditorMode?
    var fontSize: Double?
    var imageImportMode: ImageImportMode?
    var tabWidth: Int?
    var listIndentWidth: Int?
    var codeIndentWidth: Int?
    var indentationStyle: EditorIndentationStyle?
    var detectsIndentation: Bool?
    var trimsTrailingWhitespaceOnSave: Bool?
    var trimsWhitespaceOnlyLines: Bool?
    var attachmentDirectory: AttachmentDirectory?
    var markdownDialect: MarkdownDialect?
}

struct DocumentDisplayState: Codable, Equatable {
    var mode: EditorMode
    var selectionLocation: Int? = nil
    var selectionLength: Int? = nil
    var scrollY: Double? = nil
    var scrollX: Double? = nil
    var splitRatio: Double? = nil
    var splitOrientation: EditorSplitOrientation? = nil
    var previewFirst: Bool? = nil
    var sidebarTab: String? = nil
    var sidebarVisible: Bool? = nil
    var writingGoal: Int? = nil
    var sessionBaselineCharacters: Int? = nil
    var sessionBaselineCount: WritingSessionCount? = nil
    var suppressesMixedNewlinePrompt: Bool? = nil
    /// 最後に書き込んだ日時。保持件数の上限を超えたとき、古いものから削除する。
    var lastUsed: Date? = nil
}

private struct StoredEditorSettings: Codable, Equatable {
    var app = AppEditorSettings()
    var folders: [String: FolderEditorSettings] = [:]
    var documents: [String: DocumentDisplayState] = [:]
    var bookmarks: [DocumentBookmark]? = nil
}

enum MarkdownEncodingPreferences {
    // FileDocument and background folder operations read this without creating a UI store.
    static let key = "MKTownEditor.encodingDetectionOrder.v1"

    static func candidates(in defaults: UserDefaults = .standard) -> [MarkdownTextEncoding] {
        guard let stored = defaults.stringArray(forKey: key) else {
            return MarkdownTextEncoding.defaultDetectionOrder
        }
        var seen = Set<MarkdownTextEncoding>()
        return stored.compactMap(MarkdownTextEncoding.init(rawValue:)).filter { seen.insert($0).inserted }
    }
}

/// Persists shared settings while keeping document display state separate from Markdown source.
///
/// 書類ごとの表示状態は共有設定とは別のキーに保存し、件数に上限を設ける。表示位置の保存は
/// 画面に反映される値を変えないため、変更通知を送らず全ウインドウを再描画しない。
@MainActor
final class EditorSettingsStore: ObservableObject {
    static let documentStateLimit = 200

    private var values: StoredEditorSettings {
        willSet { objectWillChange.send() }
    }
    private var documents: [String: DocumentDisplayState]
    private let defaults: UserDefaults
    @Published private(set) var encodingCandidates: [MarkdownTextEncoding]
    private var savedSettingsData: Data?
    private var savedDocumentsData: Data?
    private(set) var settingsWriteCount = 0
    private(set) var documentWriteCount = 0
    /// 現在のmacOSの外観。外観に合わせて切り替える配色を決めるのに使う。
    /// SwiftUIの `colorScheme` はメニュー（Commands）から読めず、プレビューとミニマップでは
    /// テーマの明暗で上書きしているため、アプリの外観をここで持つ。
    private(set) var appearance: InterfaceAppearance
    private var appearanceObservation: NSKeyValueObservation?
    private static let storageKey = "MKTownEditor.editorSettings.v1"
    private static let documentStorageKey = "MKTownEditor.documentDisplayStates.v1"
    /// 内容が同じなら同じバイト列になるようにし、変更のない保存を省けるようにする。
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// `appearance` を渡すと、その外観で始めてmacOSの外観を監視しない（テストでホストの外観に左右されないようにする）。
    init(defaults: UserDefaults = .standard, prunesMissingDocuments: Bool = true,
         appearance: InterfaceAppearance? = nil) {
        self.defaults = defaults
        encodingCandidates = MarkdownEncodingPreferences.candidates(in: defaults)
        self.appearance = appearance ?? InterfaceAppearance(NSApplication.shared.effectiveAppearance)
        let storedData = defaults.data(forKey: Self.storageKey)
        var stored = storedData.flatMap { try? JSONDecoder().decode(StoredEditorSettings.self, from: $0) }
            ?? StoredEditorSettings()
        stored.app.restoreNavyEditorThemes()
        let documentData = defaults.data(forKey: Self.documentStorageKey)
        if let documentData,
           let decoded = try? JSONDecoder().decode([String: DocumentDisplayState].self, from: documentData) {
            documents = decoded
        } else {
            // 以前の版は共有設定と同じ値に書類の状態を含めていた。
            documents = stored.documents
        }
        let migrates = !stored.documents.isEmpty
        stored.documents = [:]
        values = stored
        savedSettingsData = migrates ? nil : storedData
        savedDocumentsData = documentData
        let loadedCount = documents.count
        trimDocuments()
        if migrates || documents.count != loadedCount {
            save()
            saveDocuments()
        }
        if prunesMissingDocuments { schedulePruningMissingDocuments() }
        if appearance == nil { observeApplicationAppearance() }
    }

    var app: AppEditorSettings { values.app }

    /// 設定と現在の外観から決まる、対象で使う配色。
    func theme(for target: ThemeTarget) -> PreviewTheme {
        values.app.theme(for: target, appearance: appearance)
    }

    /// 編集画面で使う配色。「システム」は「紺色」になっている。
    var editorTheme: PreviewTheme { theme(for: .editor) }
    /// プレビューで使う配色。
    var previewTheme: PreviewTheme { theme(for: .preview) }

    /// メニューなどで選んだ配色を保存する。外観に合わせて切り替えるなら、現在の外観の側を変える。
    func selectTheme(_ theme: PreviewTheme, for target: ThemeTarget) {
        values.app.selectTheme(theme, for: target, appearance: appearance)
        save()
    }

    /// 外観を更新する。明暗が変わったときだけ変更を通知する。テストからも外観の変化を再現するのに使う。
    func updateAppearance(_ appearance: InterfaceAppearance) {
        guard appearance != self.appearance else { return }
        objectWillChange.send()
        self.appearance = appearance
    }

    /// アプリの外観（`effectiveAppearance`）の変化を監視する。システム設定で外観を変えたときや、
    /// 自動切り替えで明暗が変わったときに通知される。
    private func observeApplicationAppearance() {
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            // KVOは値を変えたスレッドで呼ばれる。外観はメインスレッドで変わるが、念のため別スレッドにも備える。
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.updateAppearanceFromApplication() }
            } else {
                Task { @MainActor in self?.updateAppearanceFromApplication() }
            }
        }
    }

    private func updateAppearanceFromApplication() {
        updateAppearance(InterfaceAppearance(NSApplication.shared.effectiveAppearance))
    }

    func shortcut(for command: EditorCommand) -> ShortcutChord? {
        EditorShortcutRegistry.shortcut(for: command,
                                        overrides: values.app.shortcutOverrides ?? [:])
    }

    func setShortcut(_ chord: ShortcutChord, for command: EditorCommand) throws {
        var normalized = chord
        normalized.key = chord.key.lowercased()
        try EditorShortcutRegistry.validate(normalized, for: command,
            overrides: values.app.shortcutOverrides ?? [:])
        values.app.shortcutOverrides = values.app.shortcutOverrides ?? [:]
        values.app.shortcutOverrides?[command.toolbarIdentifier] = normalized
        save()
    }

    /// Leaves the command without a shortcut, even one it has by default.
    func clearShortcut(for command: EditorCommand) {
        values.app.shortcutOverrides = values.app.shortcutOverrides ?? [:]
        values.app.shortcutOverrides?[command.toolbarIdentifier] = ShortcutChord(key: "")
        save()
    }

    func resetShortcut(for command: EditorCommand) throws {
        var remaining = values.app.shortcutOverrides ?? [:]
        remaining[command.toolbarIdentifier] = nil
        if let defaultShortcut = EditorShortcutRegistry.shortcut(for: command, overrides: [:]) {
            try EditorShortcutRegistry.validate(defaultShortcut, for: command,
                                                overrides: remaining)
        }
        values.app.shortcutOverrides = remaining
        save()
    }

    func setAppSettings(_ settings: AppEditorSettings) {
        values.app = settings
        save()
    }

    var settingsArchiveSnapshot: SettingsArchive.Snapshot {
        SettingsArchive.Snapshot(
            app: app,
            encodingCandidates: encodingCandidates,
            exportPresets: MarkdownExportPresetStore(defaults: defaults).customPresets()
        )
    }

    func exportSettings(categories: Set<SettingsArchive.Category>) throws -> Data {
        try SettingsArchive(snapshot: settingsArchiveSnapshot, categories: categories).encoded()
    }

    func importSettings(_ archive: SettingsArchive, categories: Set<SettingsArchive.Category>) throws {
        let current = settingsArchiveSnapshot
        let imported = archive.merging(into: current, categories: categories)
        if imported.exportPresets != current.exportPresets {
            // Encode and validate the separate preset store before changing any other settings.
            try MarkdownExportPresetStore(defaults: defaults).replaceCustomPresets(imported.exportPresets)
        }
        if imported.encodingCandidates != current.encodingCandidates {
            storeEncodingCandidates(imported.encodingCandidates)
        }
        if imported.app != current.app { setAppSettings(imported.app) }
    }

    func setDetectionEnabled(_ enabled: Bool, for encoding: MarkdownTextEncoding) {
        guard enabled != encodingCandidates.contains(encoding) else { return }
        var candidates = encodingCandidates
        if enabled {
            candidates.append(encoding)
        } else {
            candidates.removeAll { $0 == encoding }
        }
        storeEncodingCandidates(candidates)
    }

    func moveEncodingCandidate(_ encoding: MarkdownTextEncoding, by offset: Int) {
        guard let index = encodingCandidates.firstIndex(of: encoding),
              encodingCandidates.indices.contains(index + offset) else { return }
        var candidates = encodingCandidates
        candidates.swapAt(index, index + offset)
        storeEncodingCandidates(candidates)
    }

    private func storeEncodingCandidates(_ candidates: [MarkdownTextEncoding]) {
        encodingCandidates = candidates
        defaults.set(candidates.map(\.rawValue), forKey: MarkdownEncodingPreferences.key)
    }

    func setFolderSettings(_ settings: FolderEditorSettings?, for folderURL: URL) {
        let key = Self.key(for: folderURL)
        values.folders[key] = settings
        save()
    }

    func folderSettings(for folderURL: URL) -> FolderEditorSettings {
        values.folders[Self.key(for: folderURL)] ?? FolderEditorSettings()
    }

    func attachmentDirectory(for documentURL: URL?) -> AttachmentDirectory {
        guard let documentURL else { return values.app.attachmentDirectory ?? .assets }
        return nearestFolderValue(for: documentURL, \.attachmentDirectory)
            ?? values.app.attachmentDirectory ?? .assets
    }

    func markdownDialect(for documentURL: URL?) -> MarkdownDialect {
        guard let documentURL else { return values.app.markdownDialect ?? .extended }
        return nearestFolderValue(for: documentURL, \.markdownDialect)
            ?? values.app.markdownDialect ?? .extended
    }

    func mode(for documentURL: URL?) -> EditorMode {
        guard let documentURL else { return values.app.defaultMode }
        let path = Self.key(for: documentURL)
        if let state = documents[path] { return state.mode }
        return nearestFolderValue(for: documentURL, \.defaultMode) ?? values.app.defaultMode
    }

    func fontSize(for documentURL: URL?) -> Double {
        guard let documentURL else { return values.app.fontSize }
        return nearestFolderValue(for: documentURL, \.fontSize) ?? values.app.fontSize
    }

    func imageImportMode(for documentURL: URL?) -> ImageImportMode {
        guard let documentURL else { return values.app.imageImportMode ?? .managedCopy }
        return nearestFolderValue(for: documentURL, \.imageImportMode)
            ?? values.app.imageImportMode ?? .managedCopy
    }

    func textStyle(for documentURL: URL?) -> EditorTextStyle {
        EditorTextStyle(
            font: values.app.editorFont,
            fontSize: min(32, max(10, fontSize(for: documentURL))) * zoom(for: .editor),
            lineSpacing: min(12, max(0, values.app.lineSpacing)) * zoom(for: .editor),
            horizontalMargin: min(48, max(8, values.app.horizontalMargin ?? 18)),
            verticalMargin: min(48, max(8, values.app.verticalMargin ?? 18)),
            tabWidth: min(8, max(2,
                documentURL.flatMap { nearestFolderValue(for: $0, \.tabWidth) }
                    ?? values.app.tabWidth ?? 4))
        )
    }

    func zoom(for surface: EditorZoomSurface) -> Double {
        let value = surface == .editor ? values.app.editorZoom : values.app.previewZoom
        return min(2, max(0.5, value ?? 1))
    }

    func adjustZoom(for surface: EditorZoomSurface, by amount: Double) {
        let value = (zoom(for: surface) + amount) * 10
        setZoom(for: surface, to: (value.rounded() / 10))
    }

    func resetZoom(for surface: EditorZoomSurface) {
        setZoom(for: surface, to: 1)
    }

    private func setZoom(for surface: EditorZoomSurface, to value: Double) {
        let value = min(2, max(0.5, value))
        switch surface {
        case .editor: values.app.editorZoom = value
        case .preview: values.app.previewZoom = value
        }
        save()
    }

    func layoutOptions(for documentURL: URL? = nil) -> EditorLayoutOptions {
        EditorLayoutOptions(
            wrapsLines: values.app.wrapsLines,
            showsLineNumbers: values.app.showsLineNumbers ?? true,
            listIndentWidth: min(8, max(2,
                documentURL.flatMap { nearestFolderValue(for: $0, \.listIndentWidth) }
                    ?? values.app.listIndentWidth ?? 2)),
            codeIndentWidth: min(8, max(2,
                documentURL.flatMap { nearestFolderValue(for: $0, \.codeIndentWidth) }
                    ?? values.app.codeIndentWidth ?? 4))
        )
    }

    func whitespaceEditingOptions(for documentURL: URL?) -> EditorWhitespaceEditingOptions {
        EditorWhitespaceEditingOptions(
            indentationStyle: documentURL.flatMap { nearestFolderValue(for: $0, \.indentationStyle) }
                ?? values.app.indentationStyle ?? .spaces,
            detectsIndentation: documentURL.flatMap { nearestFolderValue(for: $0, \.detectsIndentation) }
                ?? values.app.detectsIndentation ?? false,
            trimsTrailingWhitespaceOnSave: documentURL.flatMap { nearestFolderValue(for: $0, \.trimsTrailingWhitespaceOnSave) }
                ?? values.app.trimsTrailingWhitespaceOnSave ?? false,
            trimsWhitespaceOnlyLines: documentURL.flatMap { nearestFolderValue(for: $0, \.trimsWhitespaceOnlyLines) }
                ?? values.app.trimsWhitespaceOnlyLines ?? false
        )
    }

    func adjustFontSize(by amount: Double) {
        values.app.fontSize = min(32, max(10, values.app.fontSize + amount))
        save()
    }

    func resetFontSize() {
        values.app.fontSize = 13
        save()
    }

    func setImageImportMode(_ mode: ImageImportMode) {
        values.app.imageImportMode = mode
        save()
    }

    func setMode(_ mode: EditorMode, for documentURL: URL) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode)
        state.mode = mode
        storeDocumentState(state, for: key)
    }

    func applyWorkspaceLayout(_ layout: WorkspaceNamedLayout, to documentURL: URL) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: layout.mode)
        state.mode = layout.mode
        state.sidebarTab = layout.sidebarTab
        state.sidebarVisible = layout.sidebarVisible
        state.splitRatio = min(0.8, max(0.2, layout.splitRatio))
        state.splitOrientation = layout.splitOrientation
        state.previewFirst = layout.previewFirst
        storeDocumentState(state, for: key)
    }

    func displayState(for documentURL: URL) -> DocumentDisplayState? {
        documents[Self.key(for: documentURL)]
    }

    func shouldAskAboutMixedNewlines(in format: MarkdownTextFormat, at url: URL?) -> Bool {
        guard format.hasMixedNewlines, let url, values.app.asksAboutMixedNewlines != false else { return false }
        return displayState(for: url)?.suppressesMixedNewlinePrompt != true
    }

    func suppressMixedNewlinePrompt(for url: URL) {
        let key = Self.key(for: url)
        var state = documents[key] ?? DocumentDisplayState(mode: mode(for: url))
        guard state.suppressesMixedNewlinePrompt != true else { return }
        state.suppressesMixedNewlinePrompt = true
        storeDocumentState(state, for: key)
    }

    var hasSuppressedMixedNewlinePrompts: Bool {
        documents.values.contains { $0.suppressesMixedNewlinePrompt == true }
    }

    func resetMixedNewlinePrompts() {
        guard hasSuppressedMixedNewlinePrompts else { return }
        objectWillChange.send()
        for key in documents.keys where documents[key]?.suppressesMixedNewlinePrompt == true {
            documents[key]?.suppressesMixedNewlinePrompt = nil
        }
        saveDocuments()
    }

    func setWritingGoal(_ goal: Int?, for documentURL: URL) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        state.writingGoal = goal.flatMap { $0 > 0 ? $0 : nil }
        storeDocumentState(state, for: key)
    }

    /// Capture the opening text before asynchronous analysis has produced statistics.
    func ensureWritingSession(for documentURL: URL, initialText: String) {
        guard documents[Self.key(for: documentURL)]?.sessionBaselineCharacters == nil else { return }
        ensureWritingSession(for: documentURL, baseline: WritingSessionBaseline(text: initialText))
    }

    func ensureWritingSession(for documentURL: URL, baseline: WritingSessionBaseline) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        guard state.sessionBaselineCharacters == nil else { return }
        state.sessionBaselineCharacters = baseline.characters
        storeDocumentState(state, for: key)
    }

    func resetWritingSession(for documentURL: URL, baseline: WritingSessionBaseline) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        state.sessionBaselineCharacters = baseline.characters
        state.sessionBaselineCount = nil
        storeDocumentState(state, for: key)
    }

    func setWritingSessionCount(_ count: WritingSessionCount, for documentURL: URL) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        guard state.sessionBaselineCount != count else { return }
        state.sessionBaselineCount = count
        storeDocumentState(state, for: key)
    }

    func savePosition(for documentURL: URL, selection: NSRange, scrollX: Double, scrollY: Double,
                      splitRatio: Double, sidebarTab: String, sidebarVisible: Bool,
                      splitOrientation: EditorSplitOrientation = .sideBySide,
                      previewFirst: Bool = false) {
        let key = Self.key(for: documentURL)
        var state = documents[key] ?? DocumentDisplayState(mode: mode(for: documentURL))
        state.selectionLocation = max(0, selection.location)
        state.selectionLength = max(0, selection.length)
        state.scrollY = max(0, scrollY)
        state.scrollX = max(0, scrollX)
        state.splitRatio = min(0.8, max(0.2, splitRatio))
        state.splitOrientation = splitOrientation
        state.previewFirst = previewFirst
        state.sidebarTab = sidebarTab
        state.sidebarVisible = sidebarVisible
        guard documents[key] != state else { return }
        storeDocumentState(state, for: key, publishes: false)
    }

    func hasDocumentState(for documentURL: URL) -> Bool {
        documents[Self.key(for: documentURL)] != nil
    }

    func moveDocumentState(from oldURL: URL, to newURL: URL) {
        let oldKey = Self.key(for: oldURL)
        let newKey = Self.key(for: newURL)
        guard oldKey != newKey else { return }
        if let state = documents[oldKey] {
            objectWillChange.send()
            documents[oldKey] = nil
            documents[newKey] = state
            saveDocuments()
        }
        values.bookmarks = (values.bookmarks ?? []).map { bookmark in
            guard Self.key(for: bookmark.documentURL) == oldKey else { return bookmark }
            var moved = bookmark
            moved.documentURL = newURL.resolvingSymlinksInPath().standardizedFileURL
            return moved
        }
        save()
    }

    var bookmarks: [DocumentBookmark] { values.bookmarks ?? [] }

    func addBookmark(_ bookmark: DocumentBookmark) {
        var items = values.bookmarks ?? []
        items.append(bookmark)
        if items.count > 500 { items.removeFirst(items.count - 500) }
        values.bookmarks = items
        save()
    }

    func removeBookmark(_ id: UUID) {
        values.bookmarks?.removeAll { $0.id == id }
        save()
    }

    func moveBookmarks(under oldURL: URL, to newURL: URL) {
        let oldPath = Self.key(for: oldURL)
        let prefix = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        let newBase = newURL.resolvingSymlinksInPath().standardizedFileURL
        values.bookmarks = (values.bookmarks ?? []).map { bookmark in
            let path = Self.key(for: bookmark.documentURL)
            guard path == oldPath || path.hasPrefix(prefix) else { return bookmark }
            var moved = bookmark
            let remainder = String(path.dropFirst(oldPath.count))
            moved.documentURL = URL(fileURLWithPath: newBase.path + remainder)
            return moved
        }
        save()
    }

    /// Imports the old SceneStorage value once, without replacing an existing document preference.
    func migrateLegacyMode(_ rawValue: String?, for documentURL: URL) {
        guard let rawValue, let mode = EditorMode(rawValue: rawValue),
              !hasDocumentState(for: documentURL) else { return }
        setMode(mode, for: documentURL)
    }

    private func nearestFolderValue<Value>(
        for documentURL: URL,
        _ keyPath: KeyPath<FolderEditorSettings, Value?>
    ) -> Value? {
        var folderPath = (documentURL.standardizedFileURL.path as NSString).deletingLastPathComponent
        while !folderPath.isEmpty {
            if let setting = values.folders[folderPath]?[keyPath: keyPath] { return setting }
            if folderPath == "/" { break }
            let parent = (folderPath as NSString).deletingLastPathComponent
            guard parent != folderPath else { break }
            folderPath = parent
        }
        return nil
    }

    private static func key(for url: URL) -> String { url.standardizedFileURL.path }

    private func save() {
        guard let data = try? Self.encoder.encode(values), data != savedSettingsData else { return }
        defaults.set(data, forKey: Self.storageKey)
        savedSettingsData = data
        settingsWriteCount += 1
    }

    private func saveDocuments() {
        guard let data = try? Self.encoder.encode(documents), data != savedDocumentsData else { return }
        defaults.set(data, forKey: Self.documentStorageKey)
        savedDocumentsData = data
        documentWriteCount += 1
    }

    /// 書類の状態を書き込み、上限を超えた分を古い順に除いて保存する。
    private func storeDocumentState(_ state: DocumentDisplayState, for key: String, publishes: Bool = true) {
        var state = state
        state.lastUsed = Date()
        if publishes { objectWillChange.send() }
        documents[key] = state
        trimDocuments()
        saveDocuments()
    }

    /// 書き込み日時のある状態を、新しい順に上限まで残す。以前の版から移行した日時のない状態は
    /// 使われた順序が分からないため、上限では削除せず、ファイルが消えた時か書き込み時に整理する。
    private func trimDocuments() {
        let dated = documents.filter { $0.value.lastUsed != nil }
        let excess = dated.count - Self.documentStateLimit
        guard excess > 0 else { return }
        let oldest = dated.sorted { ($0.value.lastUsed!, $0.key) < ($1.value.lastUsed!, $1.key) }.prefix(excess)
        for (key, _) in oldest { documents[key] = nil }
    }

    var documentStateCount: Int { documents.count }

    private func schedulePruningMissingDocuments() {
        let paths = Array(documents.keys)
        guard !paths.isEmpty else { return }
        Task { [weak self] in
            let missing = await Self.missingDocumentPaths(paths)
            self?.removeDocumentStates(missing)
        }
    }

    /// 存在しない書類の状態を探す。フォルダごと見つからない書類は、取り外したボリュームなどの
    /// 一時的な不在の可能性があるため残す。
    nonisolated static func missingDocumentPaths(_ paths: [String]) async -> Set<String> {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            return Set(paths.filter { path in
                let folder = (path as NSString).deletingLastPathComponent
                var isDirectory: ObjCBool = false
                return manager.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue &&
                    !manager.fileExists(atPath: path)
            })
        }.value
    }

    func pruneMissingDocuments() async {
        removeDocumentStates(await Self.missingDocumentPaths(Array(documents.keys)))
    }

    private func removeDocumentStates(_ paths: Set<String>) {
        let removable = paths.filter { documents[$0] != nil }
        guard !removable.isEmpty else { return }
        objectWillChange.send()
        for path in removable { documents[path] = nil }
        saveDocuments()
    }
}

/// The character count a writing session starts from. It can only be made from the document
/// text itself: the background analysis snapshot is empty until it finishes, and recording
/// that as the start would count the whole existing document as newly written.
struct WritingSessionBaseline: Sendable {
    let id = UUID()
    let text: String
    let characters: Int

    init(text: String) {
        self.text = text
        characters = text.count
    }
}

struct WritingSessionCount: Codable, Equatable, Sendable {
    let options: DocumentCountOptions
    let dialect: MarkdownDialect
    let value: Int?
}
