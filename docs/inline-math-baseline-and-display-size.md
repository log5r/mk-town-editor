# インライン数式の `\displaystyle` の大きさとベースライン（issue #97）

## 症状

1. インライン数式で `\displaystyle` を指定しても（`$\displaystyle \frac{1}{k}$`）、`$$...$$` の数式ブロックより小さく描かれた。
2. `(1) 確率 $\displaystyle\frac{1}{k}$ で当選する…` のように背の高いインライン数式を置くと、分母が本文のベースラインに乗り、分子が行の上へ大きく飛び出した。`$\lim_{k\to\infty} P_k$` も、下付きの `k→∞` がベースラインに乗るため、式全体が本文より浮いて見えた。

## 原因

### 大きさ

数式ブロックは文字の大きさ21pt（表示用の書体）で描く。インライン数式は周りの文字の大きさ（プレビューの本文は15pt、HTMLは16pt）で描く。
`\displaystyle` はSwiftMathの書体（分数や `\sum` の組み方）を切り替えるだけで、文字の大きさは変えない。そのため、インライン数式の `\displaystyle` は数式ブロックより小さかった。

### 崩れ

`MarkdownMathRenderer.attachment` は、すべての数式で添付の位置を `bounds.origin.y = -2` に固定していた。
数式がベースラインより下に出る深さ（分数の分母、`\lim` の下付き、添字など）を無視していたため、画像の下端がほぼ本文のベースラインに来て、式全体が持ち上がっていた。
HTMLも `vertical-align:middle` で置いていたため、同じく数式のベースラインが本文とそろわなかった。PDFはHTMLを読み込んで作るが、読み込みが `middle` を無視するため、画像の下端がベースラインに乗っていた。

## 修正

| 箇所 | 内容 |
| --- | --- |
| `MarkdownMath.Formula.usesDisplaySize` | 数式ブロック、または先頭（空白の後、波括弧の外）が `\displaystyle` コマンドのインライン数式で真 |
| `MarkdownMathRenderer.displayFontSize` | 数式ブロックの大きさ（21pt）。プレビュー（`MarkdownMathView`・`MarkdownRenderer`）とHTMLで共通に使う |
| `MarkdownMathRenderer.fontSize(for:inlineSize:displaySize:)` | `usesDisplaySize` なら `max(displaySize, 周りの文字の大きさ)`、それ以外は周りの文字の大きさ。`displaySize` の既定値は `displayFontSize`（プレビュー） |
| `MarkdownMathRenderer.render` | 画像と、画像の下端から数式のベースラインまでの高さ（`baseline`）を返す |
| `MarkdownMathRenderer.attachment` | `bounds.origin.y = -baseline`。数式のベースラインを本文のベースラインに合わせる |
| `MarkdownMathRenderer.htmlImage` | インライン数式は `vertical-align:-<baseline>px;max-width:none`（縮めない） |
| `MarkdownHTMLExporter.MathImage` | 書き出す場所の文字の大きさで描く。集める時と埋め込む時で同じ大きさとキーを使う。キーに数式ブロックかどうかと大きさを含める |
| `MarkdownMathRenderer.alignImportedMathAttachments` | PDF（文書・スライド）で、HTMLから読み込んだ下げ幅を添付の位置に移す |

### ベースラインの求め方

`MTMathUILabel` は、式の高さ（`ascent + descent`、文字の大きさの半分未満なら半分）を上下中央に置く。式を置いた位置（`MTDisplay.position`）は公開されていないため、同じ計算で求める。

```text
baseline = (画像の高さ - max(ascent + descent, fontSize / 2)) / 2 + descent
```

画像の大きさは整数に切り上げ、高さは `fontSize / 2` 以上にする。HTMLの `width`・`height`（整数）で画像が拡大縮小されず、`-` のような低い式が画像の下にはみ出さない。切り上げで空いた分も上の式に含まれるため、画像の中のベースラインと一致する。

### 行の高さ

TextKitの実測（macOS 27、本文15pt、`lineSpacing` 3）では、添付をベースラインより下げた分も行の高さに含まれた。

| 添付（`bounds`） | TextKit 1の行の高さ | ベースラインより下 | TextKit 2の行の高さ |
| --- | --- | --- | --- |
| 高さ14、y=-2 | 21（通常の行と同じ） | 6（字の深さ＋行間） | － |
| 高さ40、y=-2 | 44 | 6 | 41＋行間3 |
| 高さ40、y=-20 | 43 | 23（20＋行間3） | 40＋行間3 |
| 高さ40、y=-30 | 48 | 33（30＋行間3） | － |

ベースラインより上は「添付の上側と文字の高さの大きいほう」、下は「添付の下側と文字の深さの大きいほう」に行間を足した高さになる。前の行の行間（3pt）が数式の上の隙間になり、その行の行間が下の隙間になる。そのため、`NSLayoutManagerDelegate` で行を広げる処理は加えていない。数式を含む行だけが広がり、ほかの行の行間は変わらない。
添付を含む `HoverLinkText` は幅いっぱいに描き、`sizeThatFits` でビュー自身の `layoutManager`（TextKit 1）を使って測る。文字だけの文字列を測る `HoverLinkTextMeasurer`、PDFの `NSTextView` もTextKit 1で、表示と測定は同じ規則で決まる。

### PDF

HTMLの読み込み（`NSAttributedString` のHTML読み込み）は `vertical-align:-14.72px` を画像の文字の `NSBaselineOffset`（-14.72）に変える。ベースラインはそろうが、TextKitは下げる前の高さも行の上側に取り、行の上に深さ分の空きができた（`\displaystyle\frac{1}{k}` の行が59ptのところ73.72pt）。`alignImportedMathAttachments` は負の `NSBaselineOffset` を持つ添付を、同じ画像で `bounds.origin.y` に下げ幅を持つ添付に置き換え、プレビューと同じ置き方にする。`vertical-align` に負の長さを付けるのは数式の画像だけなので、ほかの画像は変わらない。読み込み結果の添付は `NSTextAttachmentCell` を持ち、`bounds` を設定しても行の高さに反映されないため、置き換える。

### HTMLの数式を縮めない

書き出しのスタイルシートには `img { max-width: 100%; height: auto; }` があり、数式の画像にも当たる。幅の狭い画面では、本文より広いインライン数式が縮む。`vertical-align` の下げ幅は元の大きさの値のままなので、縮んだ数式は本文のベースラインより下がる（WebKitで、高さ21pxの式が12.5pxに縮むことを確かめた）。

CSSでは、画像の `vertical-align` を描いた幅に比例させられない。PDF（HTMLの読み込み → `alignImportedMathAttachments`）はpxの `vertical-align` を下げ幅として読むため、包む要素やスクリプトで置き換えることもしない。そこで、インライン数式の画像には `style` 属性で `max-width:none` を付け、縮めない。`style` 属性はスタイルシートの `img` の規則より優先される（スタイルシートに `!important` はない）。`height: auto` は残るが、幅が `width` 属性のままなので高さも元のまま（`height` 属性と同じ）になる。KaTeX・MathJaxのインライン数式も縮まない。本文より広い式は、狭い画面では本文の幅からはみ出す。
数式ブロック（`display:block`）はそろえるベースラインがないため、従来どおり幅に合わせて縮む。

### HTMLの数式の大きさ

HTMLでは、数式は書き出す場所の文字の大きさに合わせる（プレビューの `MarkdownRenderer` が周りのフォントの大きさを使うのと同じ考え方）。本文の大きさ `B` はプリセットの `fontSize`（標準は16px）。

| 場所 | インライン数式 | 根拠 |
| --- | --- | --- |
| 本文・リスト・表のセル・引用・コールアウト・定義リスト・図 | `B` | スタイルシートがこれらの文字の大きさを変えない |
| 見出し h1〜h6 | `B` × 2・1.5・1.17・1・0.83・0.67 | `MarkdownHTMLExporter.headingFontScales`。同じ値をスタイルシートの `h1`〜`h6` の `font-size` に書き出す |
| 脚注 | `B` × 0.9 | `footnoteFontScale`。スタイルシートの `.footnotes` の `font-size` と同じ値 |

- 数式ブロックは `21 × B / 16`。標準のプリセットでは21で、本文との比は従来と同じ。24pxのプリセットでは31.5（丸めない）。
- 先頭が `\displaystyle` のインライン数式は `max(数式ブロックの大きさ, その場所のインライン数式の大きさ)`。どのプリセットでも `$$...$$` と同じ大きさになり、見出しの中では見出しの文字に合わせる。
- 標準のプリセットの本文では、インライン数式16・数式ブロック21のまま変わらない。見出しの中の数式は16から見出しの大きさに、脚注の数式は16から14.4に変わった。
- 見出しの大きさはブラウザの既定値と同じ値をスタイルシートに明示した。既定値のままだと、コールアウト（`aside`）の中の `h1` のようにブラウザが別の大きさを使い、数式の大きさと合わなくなるため。表紙（`.cover h1`）は `revert` でブラウザの既定値に戻し、見た目を変えない。表紙と目次には数式の画像を置かない。
- 大きさは `MathImage` が式と場所の倍率（`fontScale`）から求める。集める `formulas(in:bodyFontSize:)` は区画の種類（見出しの段・脚注）から、埋め込む `inline(_:fontScale:)` は描く要素から同じ倍率を渡す。同期・非同期のどちらの書き出しも同じ関数を使う。キーに大きさを含めるため、見出しと本文の同じ式は別の画像になる。キーが食い違うと数式が原文に戻るので、場所ごとに画像が見つかることをテストで確かめる。
- 大きさはプリセットだけから決まるため、プリセットを渡さない呼び出し（スライドのPDF、リッチテキストのコピー、公開、パッケージ）は標準の大きさで、渡す呼び出し（PDF、HTMLの書き出し）はそのプリセットの大きさで、集める時と埋め込む時がそろう。

## 設計上の判断

- 数式ブロックの大きさにそろえるのは、式の先頭の `\displaystyle` だけにした。式全体の書体を指定したと読み取れるためである。`x + \displaystyle\frac{1}{k}` のように途中から指定した場合や、`{\displaystyle x}`、分数1つだけの `\dfrac` は、周りの文字と同じ大きさのまま、SwiftMathの書体だけを切り替える。
- 見出しのように周りの文字が21ptより大きい場合は、周りの文字に合わせる（`max`）。
- 文字の書体（`labelMode`）は従来どおり `display` で決め、`MarkdownMathCompatibility.normalize` の書体の追跡は変えていない。先頭の `\displaystyle` は従来からSwiftMathの書体として効いている。
- プレビューの表示倍率（`PreviewTypography.scaled`）は文字だけを拡大し、数式の画像と `bounds` は変えない（従来どおり）。数式ブロックの `MarkdownMathView` も倍率によらず21ptのため、インラインの `\displaystyle` と数式ブロックの大きさは倍率によらずそろう。ベースラインの下げ幅も画像の座標なので、倍率を変えてもずれない。数式が文字と一緒に拡大されないことは、この修正の範囲外として残した。

## 検証方法

`Tests/MKTownEditorTests/MarkdownMathBaselineTests.swift` で確認する。

- `usesDisplaySize` の判定（先頭・空白の後・`\displaystylefoo`・途中・`\dfrac`・波括弧の中・数式ブロック）と、大きさの解決。
- プレビューで `$\displaystyle\frac{1}{k}$` が `$$\frac{1}{k}$$` と同じ大きさで、`$\frac{1}{k}$` より大きいこと。
- 添付の `bounds.origin.y` が `-baseline` に等しいこと。画像のピクセルから、`x` の下端がベースラインにあり、分数の横線がベースラインの0.1〜0.45em上（数式の軸）にあること。
- 実際の構造化プレビュー（`NSHostingView` の `MarkdownPreview`、倍率1と1.5）で、段落の途中の行に置いた分数が前後の行の文字に重ならず、数式のベースラインが同じ行の文字のベースラインと一致し、行とビューの高さが広がること。`HoverLinkTextMeasurer` の測定とビューのレイアウトの高さが一致すること。
- HTMLで、インラインの `\displaystyle` が数式ブロックと同じ `width`・`height` で、`vertical-align` が `-baseline`、`max-width:none` であること（数式ブロックには付かない）。同じ式の数式ブロックとインライン数式、脚注の数式が、それぞれの置き方で出力されること。
- 幅200pxの `WKWebView` に書き出したHTMLを置き、本文より広いインライン数式が元の大きさのまま、画像の下端がベースラインより `baseline` だけ下にあること。数式ブロックは本文の幅に縮むこと。`max-width:none` を外すとこのテストは失敗する。
- 標準のプリセットで本文の数式の大きさが変わらないこと、24pxのプリセットでインライン24・数式ブロック31.5・先頭の `\displaystyle` が数式ブロックと同じ大きさになること（同期・非同期）。見出しと本文の同じ式が別の大きさで出力されること。見出し1〜6、本文、表の見出しとセル、脚注、リスト（番号・タスク・入れ子）、引用、コールアウト、引用の中の見出し、定義リストで、数式が原文に戻らず、その場所の大きさで出力されること（16px・24px、同期・非同期）。
- PDFで、添付に `NSBaselineOffset` が残らず、数式のベースラインが本文とそろい、行の上に余分な空きがないこと。

```sh
swift test --filter MarkdownMath
swift test
```

見た目は、上の段落を `MarkdownRenderer.render` で描き、`NSTextView` に流し込んで白背景のPNGに書き出して比べた（一時テストで作成し、リポジトリには残していない）。修正前は分数と `\lim` が行の上に浮き、修正後は本文のベースラインにそろった。
