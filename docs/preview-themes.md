# プレビューの配色（テーマ）

プレビューの背景、本文、見出し、リンク、コード、コードブロックの字句の色を、テーマで切り替える。macOS版の機能で、iOS版にはまだない。編集画面、HTML・PDFの書き出しには影響しない。

## 選び方

- 「MKTownEditor」→「設定…」（⌘,）→「プレビュー」→「配色」
- メニューバーの「表示」→「プレビューの配色」

どちらも同じ設定を変更する。設定はアプリ全体に適用し、変更した時点で開いているプレビューに反映して保存する。

| 区分 | テーマ | 背景 |
| --- | --- | --- |
| 基本 | システム（既定） | macOSの外観に合わせる |
| 基本 | 紙色 | 明るい |
| 標準装備 | GitHub風（ライト） | 明るい |
| 標準装備 | GitHub風（ダーク） | 暗い |
| 標準装備 | Tomorrow | 明るい |
| 標準装備 | Tomorrow Night | 暗い |
| 標準装備 | Dracula | 暗い |
| 標準装備 | Nord | 暗い |
| カスタム | 読み込んだJSONのテーマ | テーマによる |

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
- リンクの色は `PreviewLinkStyle` から描画へ渡す。SwiftUIの `Text` はリンクを tint で、`NSTextView` は `linkTextAttributes` で描き、どちらも文字列に付けた文字色（`.foregroundColor`）を無視するためである。

### 不具合: テーマのリンク色が反映されない（2026-11-21修正）

紙色を含むどのテーマでも、リンクが既定の青（アクセントカラー）で表示されていた。`PreviewTypography.themed` はリンクの範囲に文字色を付けていたが、上記のとおり描画側がその属性を使わない。属性文字列を調べるテストは通るため、画面で確認するまで気付けなかった。`Text` には `.tint`、`HoverLinkText` には `linkTextAttributes` でテーマのリンク色を渡して修正した。システム配色では従来どおりアクセントカラーで描く。文書を文字列1つで描く `MarkdownTextPreview` と埋め込み文書はテーマの色を当てないため、対象外。

## 検証

`PreviewThemePresetTests` が次を確認する。

- 全標準テーマが全字句の色を持ち、カスタムテーマと同じ検査（4.5:1）を通ること
- 名前での保存と復元、未知の名前の拒否、背景の明るさによる明暗の判定
- コードブロックの字句・見出し・リンクへの色の適用、`syntax` を省いた字句が `code` の色になること
- 4.5:1の基準、未知の字句名、書式の誤り、コントラスト不足の字句色の拒否
- この文書のサンプルJSONが読み込めること

- リンクの描画（tint と `linkTextAttributes`）にテーマのリンク色が渡ること

2026-11-21に `./start.sh` で起動したアプリ（macOSのライト外観）で次を目視した。

- 「表示」→「プレビューの配色」で全8種を切り替え、背景・本文・見出し・リンク・インラインコード・表・コードブロックの字句・diffの色が変わること
- 設定の「配色」がメニューの選択と一致すること
- 「カスタムテーマを読み込む…」でこの文書のサンプルを読み込むと、その場で選択されて反映されること。「拡張」で削除すると「システム」に戻ること

ダーク外観での表示、別ウインドウのプレビューは未確認。
