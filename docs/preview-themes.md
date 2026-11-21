# プレビューの配色（テーマ）

プレビューの背景、本文、見出し、リンク、コード、コードブロックの字句の色を、テーマで切り替える。macOS版の機能で、iOS版にはまだない。HTML・PDFの書き出しには影響しない。編集画面も同じテーマから独立して選べる（[編集画面の配色](#編集画面の配色)）。

## 選び方

- 「MKTownEditor」→「設定…」（⌘,）→「プレビュー」→「配色」
- メニューバーの「表示」→「プレビューの配色」

どちらも同じ設定を変更する。設定はアプリ全体に適用し、変更した時点で開いているプレビューに反映して保存する。

| 区分 | テーマ | 背景 |
| --- | --- | --- |
| 基本 | システム（既定） | GitHub風と同じ背景（ライト外観で #FFFFFF、ダーク外観で #0D1117）。文字はmacOSの色 |
| 基本 | 紙色 | 明るい |
| 標準装備 | GitHub風（ライト） | 明るい |
| 標準装備 | GitHub風（ダーク） | 暗い |
| 標準装備 | Tomorrow | 明るい |
| 標準装備 | Tomorrow Night | 暗い |
| 標準装備 | Dracula | 暗い |
| 標準装備 | Nord | 暗い |
| カスタム | 読み込んだJSONのテーマ | テーマによる |

「システム」は背景だけをGitHub風（ライト／ダーク）にそろえ、文字・見出し・リンクの色はmacOSの色のまま外観に追従する（2026-11-22から。以前は背景を塗らず、ウインドウの背景が見えていた）。背景は外観で解決する動的な `NSColor`（`PreviewTheme.systemPreviewBackground`）で、`PreviewTheme.previewBackground` が「システム」ではこの色、ほかのテーマではテーマの背景を返す。白い背景で行内コードの範囲が消えないよう、行内コードの背景も `controlBackgroundColor`（ライト外観で白）からGitHub風のコード背景（#F6F8FA / #151B23、`systemPreviewCodeBackground`）に変えた。一時停止中の帯（`PreviewUpdateControls`）も `controlBackgroundColor` で白いプレビューと同化するため、バーの素材（`.bar`）と下端の区切り線にした。コードブロックの枠、表の罫線と見出し行、引用線は文字色を薄く重ねて作るため、白い背景でも見える。

「システム」以外は、macOSの外観がダークでもテーマの色で表示する。ダーク外観でプレビューが暗すぎる場合は、明るいテーマか、背景が真っ黒でないTomorrow Night・Dracula・Nordを選ぶ。

## カスタムテーマの追加

「設定」→「プレビュー」→「カスタムテーマを読み込む…」でJSONファイルを選ぶ。読み込んだテーマはその場で選択される。削除は「設定」→「拡張」で行う。同じ `id` のファイルを読み込み直すと上書きする。

JSONは宣言的な拡張（`DeclarativeExtension`）の形式で、色を `#RRGGBB` で書く。コードは実行しない。色の決め方、他のエディタの配色の移し方、読み込めないときの直し方は[カスタムテーマの作り方](preview-theme-authoring.md)にまとめている。

<!-- PreviewThemePresetTests.testDocumentedExampleThemeLoads がこのJSONを読み込んで検証する -->
```json
{
  "schemaVersion": 1,
  "id": "example.soft-light",
  "name": "Soft Light",
  "theme": {
    "name": "Soft Light",
    "background": "#FBFAF7",
    "body": "#2B2B2B",
    "heading": "#1B3A57",
    "code": "#2B2B2B",
    "link": "#1558B0",
    "codeBackground": "#F0EEE8",
    "syntax": {
      "keyword": "#8A2C6B",
      "type": "#1B5E7A",
      "string": "#8C3B12",
      "comment": "#636363",
      "number": "#3A3FA8",
      "attribute": "#6B5300",
      "variable": "#1F5F5B",
      "inserted": "#1D6630",
      "deleted": "#A11F2B"
    }
  }
}
```

| キー | 用途 | コントラストの相手 |
| --- | --- | --- |
| `background` | プレビューの背景。明るさから明・暗の外観を決める | — |
| `body` / `heading` / `link` | 本文、見出し、リンク | `background` |
| `code` | インラインコード、コードブロックの地の文字、コピーボタン | `background` と `codeBackground` |
| `codeBackground` | インラインコードとコードブロックの背景 | — |
| `syntax` | コードブロックの字句の色。省略できる。省いた字句は `code` の色になる | `codeBackground` |

`syntax` のキーは `keyword`、`type`、`string`、`comment`、`number`、`attribute`、`variable`、`inserted`、`deleted`（[字句の種類](code-syntax-highlighting.md#字句の種類と配色)）。これ以外のキーや `#RRGGBB` でない値があると読み込まない。

文字色は相手の背景に対して4.5:1以上（WCAG AA、Human Interface Guidelinesの最低基準）のコントラストが必要で、足りないテーマは読み込まない。以前は7:1を求めていたが、GitHubのリンク色（白地で約5.2:1）のような一般的な配色を読み込めなかったため、2026-11-21に4.5:1へ下げた。ファイルは100KBまで。

## 標準装備の配色の出典と権利

色の値だけを自前の定義（`PreviewThemePreset`）に書いており、元のプロジェクトのファイルは同梱していない。いずれもMIT Licenseで公開されているパレットで、著作権表示は[サードパーティのライセンス](third-party-licenses.md#プレビューの配色)に載せている。

| テーマ | 出典 | ライセンス |
| --- | --- | --- |
| GitHub風 | [primer/primitives](https://github.com/primer/primitives)、[github-markdown-css](https://github.com/sindresorhus/github-markdown-css) | MIT |
| Tomorrow / Tomorrow Night | [chriskempson/tomorrow-theme](https://github.com/chriskempson/tomorrow-theme) | MIT |
| Dracula | [dracula/dracula-theme](https://github.com/dracula/dracula-theme) | MIT |
| Nord | [nordtheme/nord](https://github.com/nordtheme/nord) | MIT |

- GitHubの配色は、GitHubの製品や推奨と誤解されないよう「GitHub風」と表示する。GitHubのブランドガイドラインに、第三者のテーマ名を直接扱う規定は見つからなかった。
- **Monokaiは標準装備にしていない。** 原典（Wimer Hazenberg、2006年）には明示的なライセンスが見つからず、商標登録の有無も確認できなかった（2026-11-21調査）。highlight.jsやPygmentsは独自実装を自分のライセンスで配布しているが、原作者の許諾は示していない。使いたい場合は、利用者が上の形式でカスタムテーマとして追加する。
- Solarizedは本文色と背景のコントラストが4.5:1に届かない（明るい版で約4.1:1）ため、採用していない。

### コントラストのための補正

標準装備の配色は、字句の色がコード背景に対して4.5:1に届かない場合に、色相を保って明度だけを補正している。元の値と異なる色は次のとおり。

| テーマ | 字句 | 元の色 | 補正後 |
| --- | --- | --- | --- |
| Tomorrow | keyword | #8959A8 | #8858A6 |
| Tomorrow | type | #4271AE | #3F6CA7 |
| Tomorrow | string / inserted | #718C00 | #5E7400 |
| Tomorrow | comment | #8E908C | #6A6C69 |
| Tomorrow | number | #F5871F | #A25914 |
| Tomorrow | attribute | #3E999F | #30767A |
| Tomorrow Night | variable / deleted | #CC6666 | #D27878 |
| Dracula | comment | #6272A4 | #7B89B3 |
| Nord | comment | #616E88 | #8A94A7 |
| Nord | deleted | #BF616A | #CB7F86 |

Nordのコード背景は、公式のnord1（#3B4252）では多くの字句が基準に届かないため、背景（nord0）より暗い #272C36 にした。GitHub風は2026-11時点のPrimerの値を使い、補正していない。

## 実装

- `PreviewTheme`（`EditorSettings.swift`）に `.preset(PreviewThemePreset)` を追加した。設定には `"nord"` のような名前で保存する。システムと紙色は従来どおり `"system"`、`"paper"`、カスタムテーマは色の定義そのものを保存する。
- 標準装備の配色はカスタムテーマと同じ `DeclarativeExtension.Theme` で定義する（`PreviewThemePreset.swift`）。`PreviewTheme.definition` が両者を同じ経路で扱うため、色の適用（`PreviewTypography.themed`）、コードブロックの枠、明暗の判定に分岐はない。
- `DeclarativeExtension.Theme.syntax` は省略可能で、項目のない既存のJSONと保存済みの設定はそのまま読める。
- 字句の色は `CodeSyntaxPalette.color(for:theme:)` が返す。`PreviewTypography.themed` は1ブロックにつき字句の種類ごとに一度だけ色を求める。
- 選択肢は `PreviewThemeOptions` が設定とメニューの両方に並べる。
- リンクの色は `PreviewLinkStyle.textViewAttributes(for:)` から `HoverLinkText` の `linkTextAttributes` へ渡す。`NSTextView` はリンクを `linkTextAttributes` で描き、文字列に付けた文字色（`.foregroundColor`）を無視するためである。構造化プレビューは文字列をすべて `NSTextView` で描き、SwiftUIの `Text` は使わない（2026-11-22から）。

### 不具合: テーマのリンク色が反映されない（2026-11-21修正）

紙色を含むどのテーマでも、リンクが既定の青（アクセントカラー）で表示されていた。`PreviewTypography.themed` はリンクの範囲に文字色を付けていたが、描画側がその属性を使っていなかった。当時の描画には SwiftUI の `Text`（リンクを tint で描く）と `NSTextView`（`linkTextAttributes` で描く）を使っていた。属性文字列を調べるテストは通るため、画面で確認するまで気付けなかった。`Text` には `.tint`、`HoverLinkText` には `linkTextAttributes` でテーマのリンク色を渡して修正した。システム配色では従来どおりアクセントカラーで描く。文書を文字列1つで描く `MarkdownTextPreview` と埋め込み文書はテーマの色を当てないため、対象外。

2026-11-22 に構造化プレビューの文字列をすべて `HoverLinkText` で描くようにし、`Text` に `.tint` を渡す経路（`PreviewLinkStyle.tint`）は削除した。現在は `linkTextAttributes` だけでテーマのリンク色を渡す。

## 編集画面の配色

2026-11-21に追加。編集画面（左側の原文）の背景、文字、選択範囲、カーソル、行番号、Markdownの記号、コードの字句の色を、プレビューとは別に選ぶ。

### 選び方と既定

- 「設定…」（⌘,）→「エディタ」→「表示」→「配色」
- メニューバーの「表示」→「エディタの配色」

選択肢はプレビューと同じ（`PreviewThemeOptions`）で、基本・標準装備・読み込んだカスタムテーマの順に並ぶ。「エディタ」の「カスタムテーマを読み込む…」は、読み込んだテーマを編集画面に選ぶ。追加したテーマはプレビューと共通で、「拡張」で削除する。

設定が未保存のとき（初回起動や、以前の版の設定）は **システム** で表示する（2026-11-22から。2026-11-21〜22の版はGitHub風（ダーク）だった）。値は `AppEditorSettings.editorTheme` に `PreviewTheme` と同じ形で保存し、`nil` を既定として `effectiveEditorTheme` が `EditorThemePalette.defaultTheme`（`.system`）を返す。以前の版で明示的にGitHub風（ダーク）を選んで保存した設定は `"github-dark"` のまま残り、新しい既定に置き換わらない。編集画面で選んでいたカスタムテーマを削除すると、未設定（既定の「システム」）に戻す。プレビューは従来どおり「システム」に戻す。

### 編集画面の「システム」

編集画面の「システム」は、GitHub風（ダーク）の文字色（本文・リンク・コードの字句）を紺の背景 **#283264** に載せた配色（`EditorThemePalette.systemColors`）で、macOSの外観がライトでもダークの外観（`darkAqua`）で表示する。プレビューの「システム」と違い外観に追従しないのは、背景を固定の紺にしたためである。ミニマップも `PreviewTheme.editorColors` を通じて同じ紺とダークの外観になる。設定に保存する値は `"system"` のままで、色は `editorColors` が「システム」のときだけ `systemColors` に置き換えて求める。

GitHub風（ダーク）の色のうち、リンク色 #4493F8（約3.9:1）とコメント色 #9198A1（約4.2:1）は紺の背景で4.5:1に届かない。そのため見出し・リンク（リンク色）と、記号・行番号（コメント色）は下の補正で明度を上げた色になる。そのほかの字句の色（4.8:1以上）と本文（約11:1）はそのまま使う。

選んだ理由：利用者が初期配色を「システム」と呼んでおり、以前の版の「システム」（macOSの外観に追従する `textBackgroundColor` と `.systemBlue` などの色）は無骨という要望だった。紺の背景はGitHub風（ダーク）の #0D1117 より明るく、白いプレビューと並べても黒い帯に見えない。

### テーマの色の割り当て

テーマはプレビュー向けの色しか持たないため、編集画面にだけある要素の色を `EditorThemePalette`（`EditorThemePalette.swift`）が次のように導く。テーマの定義（`DeclarativeExtension.Theme`）は増やしていない。カスタムテーマのJSONもそのまま編集画面に使える。

| 編集画面の要素 | 使うテーマの色 |
| --- | --- |
| 背景、行番号の背景 | `background` |
| 本文、カーソル、選択中の文字 | `body` |
| 見出し | `heading`。本文と同じ色のテーマ（GitHub風、Tomorrow、Tomorrow Night）は `link` |
| リンク | `link` |
| インラインコード、言語指定のないコードブロック、フェンス行 | `code`。本文と同じ色のテーマは字句 `string`（なければ `code`） |
| 強調などの記号、行番号の文字 | 字句 `comment`（なければ `body`） |
| 引用の記号 / リストの記号 / タスクの記号 / 表の区切り | 字句 `attribute` / `keyword` / `inserted` / `type`（なければ記号と同じ色） |
| コードブロックの字句 | `syntax` の各色。指定のない字句は `code`（プレビューと同じ） |
| 選択範囲 | `link` を背景に30%混ぜた色 |

- 選択範囲では文字を本文の色にする（`selectedTextAttributes`）。字句の色のまま選択色に重ねると、Draculaのリンク色などで2:1を下回るためである。システム配色の選択（選択色と `selectedTextColor`）と同じ考え方である。本文と選択色のコントラストは標準装備の6種で5:1以上、紙色を含む全テーマで4.5:1以上ある。カスタムテーマは本文を背景に対してしか検査しないため、選択色に対して4.5:1に届かない場合は、選択中の文字の色（`selectedText`）だけ明度を補正する。白か黒のどちらかは必ず4.5:1以上になるため、補正は必ず基準を満たす。
- テーマの背景の明るさから、編集画面のスクロールビューに `darkAqua` か `aqua` の外観を設定する。プレースホルダー、不可視文字、インデントガイド、控えめに表示した記号、スクロールバー、検索バー、スペルの下線はシステムの色のまま、この外観で背景になじむ。ミニマップも `EditorThemeSurface` で同じ明暗と背景にする。
- 「システム」も上の割り当てで紺の配色から色を導き、ダークの外観を設定する（2026-11-22から。以前は `.systemBlue` などのシステムの色のまま外観を設定しなかった）。

### コントラストの補正

プレビュー用のテーマは字句の色をコード背景（`codeBackground`）に対して検査する。編集画面は `background` に描くため、DraculaとNordでは一部の色が4.5:1に届かない（Draculaのコメント #7B89B3 は #282A36 に対して約4.1:1）。`EditorThemePalette.readable` が、届かない色を暗い背景では白、明るい背景では黒へ5%ずつ寄せ、最初に4.5:1を満たした色を使う。カスタムテーマの色も同じ補正を受ける。テーマの値そのものは変えないため、プレビューの色は変わらない。

### 適用の経路

- `MarkdownTextEditor` は `theme` を受け取り、変わったときだけ `EditorThemePalette` を作って `apply(to:in:)` で背景・文字色・カーソル・選択・外観・行番号（`MarkdownLineNumberRulerView.palette`）を設定する。文字色の設定は文字列全体の属性を書き換えるため、色が変わらなければ行わない。
- 構文の色は `MarkdownSyntaxHighlighter.apply(to:spans:palette:)` が配色から求める。共有解析の結果（`DocumentSnapshot.syntaxSpans`）は役割だけを持ち、色を持たない。そのためテーマを切り替えても再解析せず、`Coordinator.refreshSyntax` が配色の変化を塗り直しの条件に加えて全体を塗り直す。Tree-sitterの字句（[Tree-sitterの統合](tree-sitter-integration.md)）も同じ経路で色が変わる。
- 設定は `EditorSettingsStore` に保存し、全ウインドウの `EditorWorkspace` が同じストアを監視するため、切り替えは開いているすべての編集画面にすぐ反映する。

### 迷った点

- **テーマ定義の共通化**：編集画面専用の色（記号、選択、カーソル）をJSONの形式や標準テーマに追加することも考えたが、カスタムテーマの作り方が複雑になる。既存の色からの導出で全標準テーマが基準を満たしたため、定義は増やさなかった。
- **選択範囲の色**：各テーマの公式の選択色（Draculaの #44475A など）は灰色系が多いが、灰色はmacOSの非アクティブな選択に見える。macOSの選択色がアクセントカラーに従うのに合わせ、テーマのリンク色を混ぜた。
- **カーソルの色**：macOS 14以降の既定はアクセントカラーだが、テーマの背景で確実に見えるよう本文の色にした。

## 検証

`EditorThemeTests` が編集画面の配色について次を確認する。

- 設定が未保存なら編集画面は「システム」（背景 #283264、`darkAqua`）で、プレビューは未設定（システム）のままであること。以前の版の設定も同じに読むこと
- 編集画面の配色の保存と復元、以前の既定（GitHub風（ダーク））を明示的に選んだ設定が新しい既定に置き換わらないこと
- 「システム」の編集画面の配色が紺の背景・GitHub風（ダーク）の文字色・ダークの外観で、全要素が背景に対して4.5:1以上あること。補正の要らない字句の色は変えないこと、ライト外観でも同じ紺であること（`testSystemPaletteUsesNavyBackgroundWithGitHubDarkColors`）
- ミニマップ用の色（`editorColors`）が「システム」で紺とダークになり、ほかのテーマは変わらないこと
- カスタムテーマを編集画面に選べること、読み込み直しで選択が移ること、削除で既定に戻ること
- 全テーマで、編集画面の全要素の色が背景に対して、本文が選択色に対して4.5:1以上であること。補正が働くこと、補正が不要な色は変えないこと
- 2つのウインドウの編集画面が、テーマの切り替えで背景・文字色・選択・外観・行番号・見出しとJavaScript（Tree-sitter）の字句の色をすぐに変えること

`PreviewThemePresetTests` が次を確認する。

- 全標準テーマが全字句の色を持ち、カスタムテーマと同じ検査（4.5:1）を通ること
- 名前での保存と復元、未知の名前の拒否、背景の明るさによる明暗の判定
- コードブロックの字句・見出し・リンクへの色の適用、`syntax` を省いた字句が `code` の色になること
- 4.5:1の基準、未知の字句名、書式の誤り、コントラスト不足の字句色の拒否
- この文書のサンプルJSONが読み込めること

- リンクの描画（`linkTextAttributes`）にテーマのリンク色が渡ること
- 「システム」のプレビューの背景がライト外観で #FFFFFF、ダーク外観で #0D1117 に解決され、システムの文字色が4.5:1以上あること。ほかのテーマはテーマの背景のままであること
- 「システム」の行内コードの背景がGitHub風のコード背景（#F6F8FA / #151B23）で、プレビューの背景と区別でき、テーマを選ぶとテーマのコード背景に置き換わること

`PreviewAccessibilityTests.testPausedBarStaysDistinctOnWhiteSystemPreviewBackground` は、一時停止中の帯を白いプレビューの背景に置いて描画し、幅いっぱいに白でない行（区切り線か帯の面）があることを確かめる。帯の背景を以前の `controlBackgroundColor` に戻すと失敗することを確認した。

2026-11-21に `./start.sh` で起動したアプリ（macOSのライト外観）で次を目視した。

- 「表示」→「プレビューの配色」で全8種を切り替え、背景・本文・見出し・リンク・インラインコード・表・コードブロックの字句・diffの色が変わること
- 設定の「配色」がメニューの選択と一致すること
- 「カスタムテーマを読み込む…」でこの文書のサンプルを読み込むと、その場で選択されて反映されること。「拡張」で削除すると「システム」に戻ること

ダーク外観での表示、別ウインドウのプレビューは未確認。

2026-11-22に、バンドルIDを変えたReleaseビルドで、ライト外観のmacOS 27.2で次を目視した。名称未設定の書類の分割表示で、エディタの背景が紺、プレビューの背景が白になった。本文のある書類のプレビュー表示で、背景が白、行内コードの背景が薄い灰色になった。本文のある書類の分割表示、ダーク外観、一時停止中の帯は、画面操作が中断されたため実機では確認していない。
