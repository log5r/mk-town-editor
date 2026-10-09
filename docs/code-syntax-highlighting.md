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
| SQL | `sql`、`postgresql`、`sqlite`（`"name"`は識別子として色分けしない） |
| MySQL | `mysql`、`mariadb`（`#`のコメント、`` `name` ``の識別子にも対応） |
| JSON | `json`、`jsonc` |
| JSON5 | `json5`（単一引用符の文字列、引用符のないキー） |
| YAML | `yaml`、`yml` |
| TOML | `toml` |
| INI | `ini`、`cfg`、`editorconfig`（`;`のコメントにも対応） |
| Java properties | `properties`（`#`・`!`のコメント、`=`・`:`・空白の区切り） |
| HTML・XML | `html`、`xml`、`svg`、`plist`、`vue` |
| CSS | `css` |
| SCSS・Less | `scss`、`less`（`//`の行コメントにも対応） |
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
- コメントや文字列の書き方が違う方言（SCSS・Less、MySQL、JSON5、INI）は、別名でまとめず `CodeSyntaxLanguage(_:basedOn:)` で元の言語から派生させる。Java propertiesはTOML・INIと区切りもコメントも違うため、専用の行頭規則を使う。
- 正確な構文解析はしない。目的は読みやすさの補助であり、誤った色分けで原文や書き出しの内容が変わることはない。
  - Rustのライフタイム `'a` やHaskellの `x'` を文字列にしないよう、Cの系統の言語では `'` を1文字の文字リテラルとしてだけ扱う。
  - `#` の行コメント（INIは `;` も）の条件は言語ごとに違う（`CodeSyntaxLanguage.HashComments`）。Python、Ruby、PHP、PowerShell、TOMLは文字列の外ならどこでもコメント（`x=1#note`）。YAMLとINIは直前が空白か行頭の場合だけ（`https://host/#frag`はコメントではない）。シェルは単語の先頭（空白か`;&|()<>`の直後）だけ（`$#`、`a#b`はコメントではない）。Dockerfileは行の最初の空白以外の文字の場合だけ（`ENV A b # c`の`#`は引数）。Perlは`$#`以外。PHP 8とRustの`#[...]`は属性とする。属性やINI・TOMLのセクション名の閉じ括弧は、引用符の中の`]`を数えずに探す（`#[doc = "]"]`、`["a]b"]`）。
  - 文字列のエスケープ文字も言語ごとに違う。PowerShellの二重引用符の中は`` ` ``でエスケープし、バックスラッシュは普通の文字とする。C#の`"""`の生文字列はエスケープを使わず、開きと同じ数（3つ以上）の引用符で閉じる。Swiftの`#"""…"""#`は閉じ側も3つの引用符と同じ数の`#`で閉じる。
  - 閉じていない文字列やコメントは、行末（複数行の文字列・コメントはブロック末尾）までとする。
  - Dartの`r"…"`とC#の`@"…"`はバックスラッシュをエスケープとしない（`r"C:\"`で文字列が終わる）。C#の逐語的文字列は`""`を引用符として扱う。Pythonの`r"…"`は`\"`で文字列が終わらないため、エスケープを考慮して走査する。
  - YAMLのブロックスカラー（`key: |`、`- >-`）の本文は、開始行より深く字下げされた間は色分けしない。
  - JavaScript・TypeScript・Ruby・Perlの正規表現リテラル（`/[//]/g`、`/a#b/`）は文字列として扱い、中の`//`や`#`をコメントにしない。走査しながら「次の`/`が正規表現を始められるか」を状態として持つ。値（識別子、数値、文字列、`)`・`]`・`}`、後置の`x++`）の後ろの`/`は除算とし、`return`・`default`・`then`などの語（`obj.in`のようなメンバー名を除く）、演算子・区切り記号、文書の先頭の後ろは正規表現とみなす。コメントはこの状態を変えない（`= /* c */ /re/`）。`if`・`while`・`for`・`with`の条件を閉じる`)`の後ろは文の始まりとして正規表現を認める。Ruby・Perlでは、識別子の後ろに空白があり`/`の直後に空白がない場合（`puts /a#b/`）をコマンド呼び出しの引数の正規表現とする（`$x /2`や`@n /2`は除算）。
  - TOMLの裸のキーは英数字・`_`・`-`からなる（`1234 = 1`、`- = true`）。
  - YAMLのフローマッピング（`{ enabled: true }`）の中では、`:`が続く識別子と引用符付き文字列をキーとする。
  - Rubyの`=begin`・`=end`は行頭（0桁目）にある場合だけコメントの区切りとする（`x =begin`は代入）。
  - CSS・SCSS・Lessの引用符のない`url(…)`の中身は1つの文字列とし、`url(//cdn/a.png)`の`//`をコメントにしない。
  - 区切りを選べる生文字列（Rustの`r#"…"#`、Swiftの`#"…"#`、C++の`R"tag(…)tag"`）とLuaの長い括弧（`[==[…]==]`）は、同じ区切りが現れるまでを1つの字句とする。中の引用符で文字列を終えない。
  - `--` の行コメントは方言ごとに条件が違う。MySQLは直後に空白か制御文字が必要（`1--2`は式）で、Haskellは`-->`のように記号が続くと演算子になる。
  - Diffの`---`・`+++`は、ハンクの外でだけファイル見出しとする。ハンク見出し（`@@ -1,2 +1,2 @@`）の行数を数え、ハンク内の`--- x`は削除行として扱う。
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
