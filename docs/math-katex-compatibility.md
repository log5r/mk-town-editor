# KaTeX・MathJax向けの数式がプレビューで原文表示になる問題

## 症状

Zennなどで公開した記事（docs-local/test-samples の無限反復指数関数のメモ2本）を開くと、
数式の一部が描画されず、`$...$` や `$$...$$` の原文がそのまま表示された。
2本で899個ある数式のうち184個が描画できなかった。

## 原因

数式の描画に使うSwiftMath 1.7.3は、KaTeXやMathJaxで通る次の記法を解釈しない。
不正な式は原文表示にする仕様なので、該当する式だけが原文に戻っていた。

| 失敗の内訳 | 件数 | SwiftMathの応答 |
| --- | --- | --- |
| `\lt`・`\gt` | 82 | `Invalid command` |
| `\begin{equation}...\end{equation}` | 49 | `Unknown environment equation` |
| `&` のない `aligned`・`cases` | 26 | `environment can only have 2 columns` |
| `\therefore`・`\gtrless`・`\exist`・`\plusmn` | 17 | `Invalid command` |
| `\underbrace`・`\overset`・`\underset` | 11 | `Invalid command` |

このほか、式の末尾や `\end` の直前の `\\` は解析には通るが、空の行が描画されて式の下に余白ができていた。

## 対処

[MarkdownMathCompatibility.swift](../Sources/MKTownEditor/MarkdownMathCompatibility.swift) で、
SwiftMathへ渡す前にLaTeXを書き換える。`MarkdownMath.Formula` は元の `latex` と書き換え後の
`swiftMathLaTeX` を両方持ち、描画と妥当性判定には後者を、HTMLの代替テキストやVoiceOverには前者を使う。

| 元の記法 | 書き換え |
| --- | --- |
| `\begin{equation}`・`equation*` | 外して本体だけ渡す |
| `align`・`align*`、`gather*`、`eqnarray*` | `aligned`・`gather`・`eqnarray` |
| `aligned`・`split`・`eqalign`・`cases` で全行に `&` がない | 各行の末尾へ `&` を補い、空の2列目を作る |
| 末尾や `\end` 直前の `\\` | 取り除く（途中の空行は残す） |
| `\lt`・`\gt`・`\plusmn`・`\exist` | `<`・`>`・`\pm`・`\exists` |
| `\therefore`・`\because`・`\gtrless`・`\lessgtr` | `MTMathAtomFactory.add(latexSymbol:)` で記号を登録 |
| `\argmax`・`\argmin` | 添字を下に置く演算子として登録 |
| `\underbrace{式}_{注釈}` | `{{\underline{式}} \atop {\scriptstyle 注釈}}` |
| `\overbrace{式}^{注釈}` | `{{\scriptstyle 注釈} \atop {\overline{式}}}` |
| `\underset{下}{本体}`・`\overset{上}{本体}` | 同様に `\atop` で縦積み |

SwiftMathは下括弧 `⏟` を式の幅に伸ばせず、小さな記号が1つ描かれるだけだったので、
括弧は下線・上線で代用した。縦積みは1列の `gather` 表より `\atop` のほうが行間が詰まり、
周囲の式に近い大きさで描画できる。積む本体には元の書体命令（`\displaystyle` など）を付け直す。
これは `\atop` が分数と同じく中身を一段小さくするためで、書体命令は波括弧の深さごとに追跡する。

## 設計上の判断

- SwiftMathを改変せず、公開APIの記号登録と文字列の書き換えだけで対応した。依存の更新で壊れにくい。
- 書き換えは `\begin`・`\end`・`\\`・`&` の入れ子と波括弧の深さを数えて行う。正規表現では
  入れ子の環境や `\text{a & b}` を誤って扱うため。
- 対応しない環境（`array` など）や未知のコマンドは従来どおり原文表示にする。

## 検証方法

1. `swift test --filter MarkdownMathCompatibilityTests` で書き換え結果と描画を確認する。
2. 任意のMarkdownについて全数式を調べるには、`MarkdownAnalysis` の各ブロックに
   `MarkdownMath.displayFormula` と `MarkdownMath.placeholders` を適用して `Formula` を集め、
   `MTMathListBuilder.build(fromString: formula.swiftMathLaTeX, error:)` のエラーと
   `MarkdownMathRenderer.image` の結果を出力する一時テストを書く。
   修正前は上記の表のとおり184件が失敗し、修正後は0件になった。
3. 見た目は `MarkdownMathRenderer.image` のPNGを白背景に合成して確認した。
