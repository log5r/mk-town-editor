# コードブロックの色分け

[機能ガイドに戻る](features.md)

フェンス付きコードブロックの開始行に言語名を書くと、その言語の字句規則でコードを色分けします。

````markdown
```cpp
#include <iostream>
int main() { return 0; }
```
````

色分けは編集画面、プレビュー、HTML書き出し、PDF書き出し・印刷、リッチテキストのコピーに反映します。

## 言語の指定方法

| 書き方 | 扱い |
| --- | --- |
| ` ```cpp ` | 言語名または別名。大文字・小文字は区別しない |
| ` ```ruby:app.rb ` | `:` より前を言語名とする（ファイル名付きの書き方） |
| ` ```{.python} ` | Pandoc形式の属性 |
| ` ```main.cpp ` | 言語名に一致しない場合は拡張子で判定 |
| ` ```text `、` ```txt `、` ```plaintext ` | 色分けしない |
| 言語なし、未対応の言語 | 色分けしない。編集画面ではブロック全体をコードの色で表示 |

`mermaid`、`dot`、`plantuml`などの図の言語は、これまでどおり図として表示します。

## 対応言語

| 言語 | 指定できる名前 |
| --- | --- |
| C | `c`、`h` |
| C++ | `cpp`、`c++`、`cc`、`cxx`、`hpp`、`arduino` |
| C# | `csharp`、`cs`、`c#` |
| Objective-C | `objectivec`、`objective-c`、`objc`、`m`、`mm` |
| Java | `java` |
| Kotlin | `kotlin`、`kt`、`kts` |
| Scala | `scala` |
| Swift | `swift` |
| Go | `go`、`golang` |
| Rust | `rust`、`rs` |
| Dart | `dart` |
| JavaScript | `javascript`、`js`、`jsx`、`mjs`、`cjs` |
| TypeScript | `typescript`、`ts`、`tsx` |
| Python | `python`、`py`、`python3` |
| Ruby | `ruby`、`rb` |
| PHP | `php` |
| Lua | `lua` |
| Perl | `perl`、`pl` |
| Haskell | `haskell`、`hs` |
| シェル | `shell`、`sh`、`bash`、`zsh` |
| PowerShell | `powershell`、`ps1`、`pwsh` |
| SQL | `sql`、`mysql`、`postgresql`、`sqlite` |
| JSON | `json`、`jsonc`、`json5` |
| YAML | `yaml`、`yml` |
| TOML・INI | `toml`、`ini`、`properties` |
| HTML・XML | `html`、`xml`、`svg`、`plist`、`vue` |
| CSS | `css`、`scss`、`less` |
| Diff | `diff`、`patch` |
| Dockerfile | `dockerfile`、`docker` |

別名の一覧は `CodeSyntaxLanguages.aliases` が正本です。

## 字句の種類と配色

| 字句 | 例 |
| --- | --- |
| キーワード | `if`、`return`、`SELECT`、HTMLのタグ名 |
| 型 | `int`、`String`、大文字で始まる型名、CSSのセレクタ |
| 文字列 | `"text"`、`'c'`、HTMLの属性値 |
| コメント | `// note`、`/* ... */`、`# note` |
| 数値 | `42`、`0x1F`、`1.5e3`、`4px` |
| 属性 | `@Override`、`#include`、`#[derive]`、JSON・YAMLのキー、CSSのプロパティ |
| 変数 | シェル・PHPの`$name`、Rubyの`@name`・`:symbol`、HTMLの文字参照 |
| 追加行・削除行 | Diffの`+`行・`-`行 |

配色はXcodeの標準テーマに近い色です。システム配色では明るい外観と暗い外観で色を切り替え、紙色テーマでは紙色の背景向けの濃い色を使います。どの配色もコード背景に対して4.5:1以上のコントラストを保ちます（`CodeSyntaxHighlighterTests.testPalettesMeetTextContrastAgainstCodeBackgrounds`）。拡張テーマではテーマ作者が指定したコード色だけで表示します。テーマのコード色は背景との7:1のコントラストを検証済みですが、字句ごとの色はその保証を持たないためです。

HTML書き出しでは字句を`<span class="tok-keyword">`のように囲み、スタイルシートで色を指定します。画面表示用のHTMLは`prefers-color-scheme`で暗い外観の色に切り替えます。PDFと印刷は紙に出すため、明るい外観の色だけを使います。

## 設計

- 字句解析は `CodeSyntaxTokenizer` が行う。正規表現を使わず、UTF-16単位で1回だけ走査し、`NSRange`の字句列を返す。メインアクター外の文書解析（`DocumentSnapshot`）からも呼べる。
- 言語ごとの差は `CodeSyntaxLanguage` の設定値（キーワード、コメント記号、文字列の区切り、接頭辞付き識別子など）で表す。HTML・XMLとDiffだけは専用の走査を使う。
- 正確な構文解析はしない。目的は読みやすさの補助であり、誤った色分けで原文や書き出しの内容が変わることはない。
  - Rustのライフタイム `'a` やHaskellの `x'` を文字列にしないよう、Cの系統の言語では `'` を1文字の文字リテラルとしてだけ扱う。
  - シェルとYAMLの `#` は、単語の先頭にある場合だけコメントとする（`$#`、`a#b` はコメントではない）。
  - 閉じていない文字列やコメントは、行末（複数行の文字列・コメントはブロック末尾）までとする。
- 編集画面では、言語を指定したブロックのフェンス行をコードの色、本文を字句ごとの色で表示する。本文の各行は原文の行の末尾部分（引用の`> `やリストの字下げを除いた部分）として位置を対応づける。タブの展開などで対応しない行がある場合は、ブロック全体をコードの色で表示する。
- プレビューは描画結果に字句の種類（`.codeSyntaxToken`属性）を残し、`PreviewTypography.themed` がテーマの色に当て直す。

## 性能

コード5,000行（約28万字）と見出し・本文500節を含む文書で、Releaseビルドの `MarkdownSyntaxHighlighter.spans` は約25ミリ秒（コードを色分けしない場合は約7ミリ秒）、`DocumentSnapshot` 全体は約150ミリ秒だった（2026-10-09、Apple Silicon）。この計算は入力中にメインスレッド外で行う。

## テスト

```sh
swift test --filter CodeSyntaxHighlighterTests
swift test --filter MarkdownSyntaxHighlighterTests
```

言語ごとの字句、別名とファイル名付きの指定、閉じていない構文で範囲が本文を超えないこと、編集画面の原文位置（引用・リスト内を含む）、テーマ配色とコントラスト、HTML・PDF書き出しを確認します。
