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
| TypeScript | `typescript`、`ts`、`mts`、`cts` |
| TSX | `tsx` |
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

JavaScript・TypeScript・TSX・Rubyは[Tree-sitter](tree-sitter-integration.md)で構文解析し、それ以外の言語は走査器（`CodeSyntaxTokenizer`）で色分けします。別名の一覧は `CodeSyntaxLanguages.aliases` が正本です。

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

### 流れ

1. コード本文と言語名から、`CodeSyntaxAnalyzer` が正規の言語名と解析エンジンを決める。
2. JavaScript・TypeScript・TSX・RubyはTree-sitter（`TreeSitterSyntaxParser`）、それ以外は走査器（`CodeSyntaxTokenizer`）で解析する。
3. どちらも `[CodeSyntaxTokenRange]`（本文に対するUTF-16の範囲と字句の種類、位置順、重ならない）を返す。
4. 結果は文書の版ごとに `DocumentSnapshot.codeSyntaxTokens`（`MarkdownBlock.id` を鍵とする辞書）へ入れ、編集画面、プレビュー、HTML・PDF書き出し、印刷、リッチテキストのコピーが同じ結果を使う。項目があれば解析済みで、字句が無くても `[]` を持つ。

`DocumentSnapshot` はメインアクター外で作る。プレビューは、自分が描画する解析結果の字句だけを使い、書き出しは1回の書き出しにつき1回だけ計算する。表示側は字句に色を付けるだけで、解析をやり直さない。

### エンジンの境界

- SwiftTreeSitterなど外部の型は `TreeSitterSyntaxParser.swift` の外へ出さない。境界を越えるのは `CodeSyntaxTokenRange` だけである。
- クエリは自前のものを `TreeSitterGrammar` ごとに持つ。キャプチャ名は字句の種類（`keyword`、`string`、`comment` など）に、大文字始まりの型名を表す `type.capitalized` と、`require` などの組み込み名を表す `keyword.builtin` を加えたものである。
- キャプチャは入れ子になりうる（テンプレート文字列の中の式など）。内側を優先し、外側の字句は内側を除いた部分に分割する。範囲が同じキャプチャは先に書いたパターンを使う。
- `#match?` などの述語は使わない（`QueryCursor` は述語を評価しない）。述語が要る判定は、構文木の形かクエリの書き方で表す。
- 構文エラーがあっても、得られたキャプチャのうち使えるものは使う。

### 単色になる場合

次の場合は字句を付けず、ブロック全体を単色（コードの色）で表示する。原文や書き出しの内容は変わらない。

- 未対応の言語、`text` などのプレーンテキスト指定
- 本文が100万UTF-16単位を超える
- 解析が0.5秒で終わらない（タイムアウト）
- クエリのコンパイルに失敗した
- 結果が妥当でない（範囲が本文を超える、重なる、順序が逆）

### キャッシュ

- `CodeSyntaxTokenCache` は解析結果のLRUで、`CodeSyntaxAnalyzer.sharedCache` を使う。上限は128件、本文の合計2,000,000UTF-16単位。超える本文は保存しない。
- 鍵は、言語の正規名、エンジンの版、本文のハッシュである。本文そのものも保持し、一致を確かめてから返す（ハッシュの衝突で別の結果を返さない）。エンジンの版は、Tree-sitterでは文法パッケージの版とクエリの版（`TreeSitterGrammar.cacheVersion`）、走査器では走査規則の版（`scanner:2`）である。文法やクエリ、走査規則を変えたら版を上げる。
- 色や原文中の絶対位置は持たない。そのため、テーマの切り替えや、ブロックより前の編集による位置のずれでは再解析しない。
- Tree-sitterの `Parser` は呼び出しごとに作り、共有しない。複数のスレッドから同時に呼べる。
- 入力が長すぎる、クエリをコンパイルできないといった毎回同じ結果になる失敗（単色）は保存し、同じ本文を繰り返し解析しない。タイムアウトなど負荷で一時的に起きる失敗は保存せず、次の機会にやり直す。

### 取り消し

`DocumentSnapshot` の生成はブロックの合間に取り消しを確認し、古い版の解析を早く打ち切る。`DocumentAnalysisStore` は、完了した解析がその時点の本文の版と一致するときだけ結果を反映する。1つのブロックの解析中には取り消さない（最長でも上記のタイムアウトまで）。

### 走査器の規則

走査器は、Tree-sitterへ移していない言語を担当する。`CodeSyntaxTokenizer` は正規表現を使わず、UTF-16単位で1回だけ走査する。

- 言語ごとの差は `CodeSyntaxLanguage` の設定値（キーワード、コメント記号、文字列の区切り、接頭辞付き識別子など）で表す。HTML・XMLとDiffだけは専用の走査を使う。
- コメントや文字列の書き方が違う方言（SCSS・Less、MySQL、JSON5、INI）は、別名でまとめず `CodeSyntaxLanguage(_:basedOn:)` で元の言語から派生させる。Java propertiesはTOML・INIと区切りもコメントも違うため、専用の行頭規則を使う。
- 構文解析はしない。目的は読みやすさの補助であり、誤った色分けで原文や書き出しの内容が変わることはない。
  - Rustのライフタイム `'a` やHaskellの `x'` を文字列にしないよう、Cの系統の言語では `'` を1文字の文字リテラルとしてだけ扱う。
  - `#` の行コメント（INIは `;` も）の条件は言語ごとに違う（`CodeSyntaxLanguage.HashComments`）。Python、PHP、PowerShell、TOMLは文字列の外ならどこでもコメント（`x=1#note`）。YAMLとINIは直前が空白か行頭の場合だけ（`https://host/#frag`はコメントではない）。シェルは単語の先頭（空白か`;&|()<>`の直後）だけ（`$#`、`a#b`はコメントではない）。Dockerfileは行の最初の空白以外の文字の場合だけ（`ENV A b # c`の`#`は引数）。Perlは`$#`以外。PHP 8とRustの`#[...]`は属性とする。属性やINI・TOMLのセクション名の閉じ括弧は、引用符の中の`]`を数えずに探す（`#[doc = "]"]`、`["a]b"]`）。
  - 文字列のエスケープ文字も言語ごとに違う。PowerShellの二重引用符の中は`` ` ``でエスケープし、バックスラッシュは普通の文字とする。C#の`"""`の生文字列はエスケープを使わず、開きと同じ数（3つ以上）の引用符で閉じる。Swiftの`#"""…"""#`は閉じ側も3つの引用符と同じ数の`#`で閉じる。
  - 閉じていない文字列やコメントは、行末（複数行の文字列・コメントはブロック末尾）までとする。
  - Dartの`r"…"`とC#の`@"…"`はバックスラッシュをエスケープとしない（`r"C:\"`で文字列が終わる）。C#の逐語的文字列は`""`を引用符として扱う。Pythonの`r"…"`は`\"`で文字列が終わらないため、エスケープを考慮して走査する。
  - YAMLのブロックスカラー（`key: |`、`- >-`）の本文は、開始行より深く字下げされた間は色分けしない。
  - Perlの正規表現リテラルは、直前の字句だけで判定する。値（識別子、数値、文字列、閉じ括弧）の後ろの`/`は除算、記号と言語のキーワード（`print /x/`、`and /x/`）の後ろは正規表現とする。文の始まりやブロックの種類は推定しない。
  - TOMLの裸のキーは英数字・`_`・`-`からなる（`1234 = 1`、`- = true`）。引用符付きのキー（`'a=b' = 1`、`a."e=f".g = 3`）の中の`=`・`#`は区切りにしない。
  - YAMLのフローマッピング（`{ enabled: true }`）の中では、`:`が続く識別子と引用符付き文字列をキーとする。
  - CSS・SCSS・Lessの引用符のない`url(…)`の中身は1つの文字列とし、`url(//cdn/a.png)`の`//`をコメントにしない。
  - 区切りを選べる生文字列（Rustの`r#"…"#`、Swiftの`#"…"#`、C++の`R"tag(…)tag"`）とLuaの長い括弧（`[==[…]==]`）は、同じ区切りが現れるまでを1つの字句とする。中の引用符で文字列を終えない。
  - `--` の行コメントは方言ごとに条件が違う。MySQLは直後に空白か制御文字が必要（`1--2`は式）で、Haskellは`-->`のように記号が続くと演算子になる。
  - Diffの`---`・`+++`は、ハンクの外でだけファイル見出しとする。ハンク見出し（`@@ -1,2 +1,2 @@`）の行数を数え、ハンク内の`--- x`は削除行として扱う。
- 編集画面では、言語を指定したブロックのフェンス行をコードの色、本文を字句ごとの色で表示する。本文の各行は原文の行の末尾部分（引用の`> `やリストの字下げを除いた部分）として位置を対応づける。タブの展開などで対応しない行がある場合は、ブロック全体をコードの色で表示する。
- プレビューは描画結果に字句の種類（`.codeSyntaxToken`属性）を残し、`PreviewTypography.themed` がテーマの色に当て直す。

## 既知の制約

色分けは読みやすさの補助であり、取り違えても原文や書き出しの内容は変わらず、影響は色だけである。旧走査器と現在の解析の結果を比べた記録は[コード色分けエンジンの比較記録](code-syntax-engine-comparison.md)、移行の経緯は[コード色分けの設計評価](code-syntax-highlighting-design.md)にある。

Tree-sitterで解析する言語では、次の場合に色が合わない。

- Ruby：`a /2/3` のように、ローカル変数の後ろの`/`を正規表現の始まりと読む。tree-sitter-rubyはローカル変数を追跡しない。`eval`で定義した変数は対象外。
- JavaScript・TypeScript：`export default function() {}`、`export default class {}`（名前のない宣言）の直後の正規表現を誤って解析する。tree-sitter-javascriptの制約。
- Ruby：字下げした `  =end` でも `=begin` のコメントが閉じる。
- 閉じていない文字列やコメントは、その字句自身の色が付かない。前後の行の色は保たれる。

文の区切りを省いた `foo()` の次の行頭の `/re/.test(x)` は、JavaScriptの文法どおり除算として読む。これは制約ではなく文法上の扱いである。

走査器で色分けする言語は構文を解析しないため、文字列やコメントの書き方が特殊なコードでは色が合わないことがある。

## 性能

2026-10-09、Releaseビルド、Apple Siliconで、1回の空打ちのあと5回測った中央値。5,000行のブロックは、実際のコードに近い9〜10行の断片を繰り返して作った（JavaScriptは約18.6万字）。計測は `CodeSyntaxPerformanceTests` で、`MKTOWN_PERF=1` を付けたときだけ実行する。

| 項目 | 時間 |
| --- | --- |
| JavaScript 5,000行の解析（初回） | 約51ミリ秒 |
| TypeScript 5,000行の解析（初回） | 約46ミリ秒 |
| Ruby 5,000行（約12.7万字）の解析（初回） | 約50ミリ秒 |
| C 5,000行（約14.4万字）の解析（走査器、初回） | 約8ミリ秒 |
| 同じブロックのキャッシュ命中 | 0.5〜0.8ミリ秒 |
| `MarkdownSyntaxHighlighter.spans`（字句は計算済み） | 約26ミリ秒（言語のないコードブロックでは約16ミリ秒） |
| `DocumentSnapshot` 全体 | 初回約280ミリ秒、キャッシュ命中約233ミリ秒 |
| コードブロックに1文字追加した後の `DocumentSnapshot` | 約216ミリ秒 |
| `CodeSyntaxHighlighter.render`（メインアクター、字句は計算済み） | 約24ミリ秒 |
| 同上、`tokens: nil` でキャッシュ命中 | 約25ミリ秒 |
| 同上、`tokens: nil` でキャッシュが空 | 約73ミリ秒 |

文書は、JavaScript 5,000行（約18.6万字）と見出し・本文500節を合わせた約22.4万字である。`DocumentSnapshot` の大半はコード以外の解析（約230ミリ秒）で、コードブロックの解析は約50ミリ秒を占める。字句を共有するので、メインアクターで解析する場合の73ミリ秒は、プレビューや書き出しでは起きない。以前の資料にある25ミリ秒と150ミリ秒は旧実装（走査器）の値で、文書の大きさも違うため直接は比べられない。

メモリは、上限の100万UTF-16単位のJavaScriptブロック（字句67,112件）を解析してキャッシュに保持した状態で、`phys_footprint` が約2.1 MB増えた。`removeAll()` の後も、プロセスの値は解析前に戻らなかった（アロケータが返さない）。キャッシュは字句の配列だけを持つため、上限いっぱい（128件、2,000,000単位）でも同程度である。Tree-sitterの構文木は解析ごとに解放し、保持しない。

配布サイズは、Releaseの実行ファイルが `main` の21,333,168バイトから27,222,256バイトへ5,889,088バイト（約5.6 MiB）増えた。文法パッケージのリソースバンドルは4つで、合計76 KB（ディスク使用量）である。

## テスト

```sh
swift test --filter 'TreeSitter|CodeSyntax'
swift test --filter MarkdownSyntaxHighlighterTests
MKTOWN_PERF=1 swift test -c release --filter CodeSyntaxPerformanceTests 2>&1 | grep PERF
```

- `CodeSyntaxHighlighterTests`：言語ごとの字句、別名とファイル名付きの指定、閉じていない構文で範囲が本文を超えないこと、編集画面の原文位置（引用・リスト内を含む）、テーマ配色とコントラスト、HTML・PDF書き出し。
- `TreeSitterSyntaxParserTests`：クエリのコンパイル、字句の種類、入れ子の解決（内側を優先し外側を分割）、範囲の検証、大きな本文がタイムアウト内に終わること、`Package.resolved` の版と `packageVersion` の一致。
- `CodeSyntaxAnalyzerTests`：言語とエンジンの選択、キャッシュ（命中、言語・エンジンの版による分離、LRU、長さの上限、ハッシュの衝突、複数スレッド）。
- `CodeSyntaxSharingTests`：編集画面・プレビュー・書き出しが同じ字句を使うこと、プレビューがスナップショットの字句で再解析しないこと、ブロックの合間の取り消し、`DocumentAnalysisStore` が公開する字句がその版の本文のものであること。
- `CodeSyntaxPerformanceTests`：上の性能の計測。`MKTOWN_PERF=1` がなければ飛ばす。
