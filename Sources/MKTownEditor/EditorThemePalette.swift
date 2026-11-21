import AppKit
import SwiftUI

/// 編集画面の配色。プレビューと同じ `PreviewTheme`（システム・紙色・標準装備・カスタム）から作る。
///
/// テーマはプレビュー向けの色（背景、本文、見出し、リンク、コード、コードの字句）しか持たないため、
/// 編集画面だけにある要素（Markdownの記号、選択範囲、カーソル、行番号）の色はそこから導く。
/// 対応は docs/preview-themes.md の「編集画面の配色」を参照。
struct EditorThemePalette: Equatable {
    /// 設定が未保存のときの編集画面の配色。
    static let defaultTheme: PreviewTheme = .preset(.githubDark)
    /// 文字色に求める背景とのコントラスト比（WCAG AA）。テーマの色が届かなければ明度を補正する。
    static let minimumContrast = DeclarativeExtension.Theme.minimumContrast
    /// 選択範囲の背景に混ぜるリンク色の割合。
    static let selectionTint: CGFloat = 0.3

    let theme: PreviewTheme
    let background: NSColor
    let text: NSColor
    /// `nil` はシステムの既定（アクセントカラーに合わせた選択色と選択中の文字色）。
    let selection: NSColor?
    /// `nil` はシステムの既定のカーソル色。
    let insertionPoint: NSColor?
    let lineNumber: NSColor
    /// テーマの背景の明るさに合わせた外観。`nil` はmacOSの外観に従う。
    let appearanceName: NSAppearance.Name?
    let heading: NSColor
    let code: NSColor
    let link: NSColor
    let marker: NSColor
    let quoteMarker: NSColor
    let listMarker: NSColor
    let taskMarker: NSColor
    let tableMarker: NSColor
    private let tokens: [CodeSyntaxToken: NSColor]

    /// 色はテーマから決まるため、テーマが同じなら同じ配色とみなす。
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.theme == rhs.theme }

    /// macOSの外観に追従するシステムの色。テーマを選ばない編集画面（テストの既定など）もこれを使う。
    @MainActor static let system = EditorThemePalette(systemTheme: ())

    private init(systemTheme: Void) {
        theme = .system
        background = .textBackgroundColor
        text = .textColor
        selection = nil
        insertionPoint = nil
        lineNumber = .secondaryLabelColor
        appearanceName = nil
        heading = .systemBlue
        code = .systemPurple
        link = .linkColor
        marker = .secondaryLabelColor
        quoteMarker = .systemTeal
        listMarker = .systemOrange
        taskMarker = .systemGreen
        tableMarker = .systemIndigo
        tokens = Dictionary(uniqueKeysWithValues: CodeSyntaxToken.allCases.map {
            ($0, CodeSyntaxPalette.color(for: $0))
        })
    }

    @MainActor
    init(theme: PreviewTheme) {
        guard theme != .system, let background = theme.background, let body = theme.bodyColor,
              let headingColor = theme.headingColor, let linkColor = theme.linkColor,
              let codeColor = theme.codeColor else {
            self = .system
            return
        }
        func readable(_ color: NSColor) -> NSColor { Self.readable(color, on: background) }
        let syntax = Dictionary(uniqueKeysWithValues: CodeSyntaxToken.allCases.map { token in
            (token, CodeSyntaxPalette.color(for: token, theme: theme))
        })
        self.theme = theme
        self.background = background
        text = readable(body)
        // 見出しの色が本文と同じテーマ（GitHub風、Tomorrow、Tomorrow Night）は、見出しをリンク色で区別する。
        heading = readable(Self.distinct(headingColor, from: body) ?? linkColor)
        link = readable(linkColor)
        // コードの色が本文と同じテーマは、文字列の字句の色でコードを区別する。
        code = readable(Self.distinct(codeColor, from: body) ?? syntax[.string].flatMap { $0 } ?? codeColor)
        // 記号は控えめに見せるため、コメントの色を使う。字句の色がないテーマは本文の色にする。
        let comment = readable(syntax[.comment].flatMap { $0 } ?? body)
        marker = comment
        lineNumber = comment
        quoteMarker = readable(syntax[.attribute].flatMap { $0 } ?? comment)
        listMarker = readable(syntax[.keyword].flatMap { $0 } ?? comment)
        taskMarker = readable(syntax[.inserted].flatMap { $0 } ?? comment)
        tableMarker = readable(syntax[.type].flatMap { $0 } ?? comment)
        // プレビューと同じく、テーマが定めていない字句はコードの色にする。
        tokens = syntax.mapValues { readable($0 ?? codeColor) }
        selection = Self.blend(linkColor, over: background, fraction: Self.selectionTint)
        insertionPoint = text
        appearanceName = theme.colorScheme == .dark ? .darkAqua : .aqua
    }

    func color(for role: MarkdownSyntaxSpan.Role) -> NSColor {
        switch role {
        case .heading: heading
        case .code: code
        case .link: link
        case .marker: marker
        case .quoteMarker: quoteMarker
        case .listMarker: listMarker
        case .taskMarker: taskMarker
        case .tableMarker: tableMarker
        case .codeToken(let token): tokens[token] ?? code
        }
    }

    /// 選択中の文字の属性。選択範囲では字句の色をやめて本文の色にし、選択色とのコントラストを保つ。
    var selectedTextAttributes: [NSAttributedString.Key: Any] {
        guard let selection else {
            return [.backgroundColor: NSColor.selectedTextBackgroundColor,
                    .foregroundColor: NSColor.selectedTextColor]
        }
        return [.backgroundColor: selection, .foregroundColor: text]
    }

    /// 背景・文字・選択範囲・カーソル・行番号を反映する。字句の色は `MarkdownSyntaxHighlighter.apply` が当てる。
    /// システムの色（プレースホルダー、不可視文字、スクロールバー、検索の強調）は、外観を合わせて背景になじませる。
    @MainActor
    func apply(to textView: NSTextView, in scrollView: NSScrollView) {
        let appearance = appearanceName.flatMap(NSAppearance.init(named:))
        if scrollView.appearance?.name != appearance?.name { scrollView.appearance = appearance }
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        // 文字色の変更は文字列全体の属性を書き換えるため、変わるときだけ行う。
        if textView.textColor != text { textView.textColor = text }
        textView.insertionPointColor = insertionPoint
        textView.selectedTextAttributes = selectedTextAttributes
        (scrollView.verticalRulerView as? MarkdownLineNumberRulerView)?.palette = self
    }

    /// `color` が `other` と同じ色なら `nil` を返す。
    private static func distinct(_ color: NSColor, from other: NSColor) -> NSColor? {
        guard let first = color.usingColorSpace(.sRGB), let second = other.usingColorSpace(.sRGB) else { return color }
        let same = abs(first.redComponent - second.redComponent) < 0.002 &&
            abs(first.greenComponent - second.greenComponent) < 0.002 &&
            abs(first.blueComponent - second.blueComponent) < 0.002
        return same ? nil : color
    }

    static func blend(_ color: NSColor, over background: NSColor, fraction: CGFloat) -> NSColor {
        guard let top = color.usingColorSpace(.sRGB), let base = background.usingColorSpace(.sRGB) else {
            return color
        }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { b + (a - b) * fraction }
        return NSColor(srgbRed: mix(top.redComponent, base.redComponent),
                       green: mix(top.greenComponent, base.greenComponent),
                       blue: mix(top.blueComponent, base.blueComponent), alpha: 1)
    }

    /// 背景とのコントラストが基準に届かない色を、色相を保ったまま白（暗い背景）か黒（明るい背景）へ寄せる。
    /// プレビュー用のテーマはコードの字句をコード背景に対して検査するため、編集画面の背景では足りない場合がある。
    @MainActor
    static func readable(_ color: NSColor, on background: NSColor) -> NSColor {
        guard PreviewTypography.contrastRatio(color, background) < minimumContrast else { return color }
        let target: NSColor = PreviewTypography.contrastRatio(.white, background) >=
            PreviewTypography.contrastRatio(.black, background) ? .white : .black
        for step in 1...20 {
            let candidate = blend(target, over: color, fraction: CGFloat(step) / 20)
            if PreviewTypography.contrastRatio(candidate, background) >= minimumContrast { return candidate }
        }
        return target
    }
}

/// 編集画面の隣に置くSwiftUIの要素（ミニマップ）を、編集画面の配色の明暗と背景に合わせる。
/// 本文の再描画のたびに作られるため、配色全体（`EditorThemePalette`）は求めず、背景だけを使う。
struct EditorThemeSurface: ViewModifier {
    let theme: PreviewTheme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .environment(\.colorScheme, theme.colorScheme ?? colorScheme)
            .background(theme.background.map { Color(nsColor: $0) } ?? Color.clear)
    }
}

extension AppEditorSettings {
    /// 編集画面の配色。未設定なら既定のダーク系テーマ。
    var effectiveEditorTheme: PreviewTheme { editorTheme ?? EditorThemePalette.defaultTheme }
}
