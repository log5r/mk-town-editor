# プレビューの表の罫線・コールアウトの縦線・リストの行間

構造化プレビュー（`MarkdownPreview` の `LazyVStack` の経路）で報告された、見た目の3件の原因と修正をまとめる。

## 表の罫線が薄くて見えない

セルごとに `Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)` を重ねていた。副次的な文字色の20%を0.5ptで引くため、明るい背景ではほとんど見えなかった。

- 罫線の色と太さは `PreviewTableStyle` にまとめた。文字色（`Color.primary`）の30%、太さ1pt。
- セルは右と下の線だけを引き、表の上と左の線を表全体に足す。セルごとに四辺を引くと、隣り合うセルの線が重なって内側だけ濃くなる。
- 行のセルを同じ高さにそろえた（`frame(maxHeight: .infinity)` と行の `fixedSize`）。折り返したセルがある行でも縦線がつながる。

## コールアウト（`> [!note]`）の縦線が破線になる

`MarkdownRenderer.quote` は引用の各行の先頭に引用記号（`│  `）を文字として付ける。文字の高さは行の高さより短く、行間と段落の間隔の分だけ線が途切れる。

引用記号を文字で描く経路は2種類あり、それぞれ図形で引くようにした。

### 構造化プレビューのコールアウトの外側の線

縦線を1本の図形（`PreviewQuoteBar`）で引き、文字列には引用記号を付けない（`renderCalloutSegments(quotesText: false)`）。線はコードブロックの横も含め、コールアウトの中身の高さいっぱいに続く。位置と幅は引用記号の幅（約12pt）にそろえている。

通常の引用（コールアウトでないもの）は、構造化プレビューでは以前から行のビューが `Rectangle` で縦線を描いており、途切れない。

### `NSTextView` で描く文字列の中の引用

次の箇所は、複数のブロックを1つの文字列にまとめて `NSTextView`（`HoverPreviewTextView`）で描く。引用記号は文字列に残る。

- コールアウトの中の入れ子の引用。
- 全体を1つの `NSTextView` で描くプレビュー（`MarkdownTextPreview`）の引用とコールアウト。
- 埋め込み文書（`![[文書名]]`）の引用とコールアウト。

`HoverPreviewTextView` が引用記号の縦線の文字（`│`）を表示のときだけ透明にし、`PreviewQuoteBars.bars` で求めた矩形を `drawBackground(in:)` で塗る（文字の背景として描く。記号の文字は透明なので線は隠れない）。

#### 記号の文字の隠し方

- 文字列（`NSTextStorage`）の文字色は変えず、`NSLayoutManager` の一時属性（`addTemporaryAttribute(.foregroundColor, value: .clear, ...)`）で隠す（`PreviewQuoteBars.hideGlyphs`）。一時属性は画面の描画にだけ効き、コピーには含まれない。
- 以前は `aligned` が透明の文字色を文字列に書いていた。リッチテキスト（RTF）でコピーすると、記号が透明のまま出ていた（RTF は Apple の拡張で色の透明度も保存する）。
- 一時属性を付けるのは描画の前（`viewWillDraw`。`viewWillDraw` を経ない描画に備えて `drawBackground(in:)` でも、文字を描く前に付ける）。文字列が変わると `NSTextStorageDelegate` で印を付け、次の描画の前に外してから付け直す。引用がなくなった文字列では一時属性を外す。
- 引用の線を含むかは、属性 `previewQuotePrefix` の範囲に文字 `│` があるかで決める（`PreviewQuoteBars.containsBars`）。結果は文字列が変わるまで覚えておく。
- `layoutManager` に触れると `NSTextView` は TextKit 1 に切り替わる。引用の線を含まない文字列では触れない（一度一時属性を付けた後に引用がなくなった場合は、すでに切り替わっているため外すために触れる）。
- `NSTextView` の `draw(_:)` を上書きすると、そのサブクラスは作った時点で TextKit 1 になる（`textLayoutManager` が `nil`。`drawBackground(in:)`・`viewWillDraw` の上書きでは起きない。macOS 27 で確認）。線を `draw(_:)` で描いていた版では、引用を含まない文字列でも TextKit 2 を使えていなかった。なお、`HoverLinkText.sizeThatFits` は高さを求めるために `layoutManager` に触れるため、構造化プレビューの `HoverLinkText` は引用の有無によらず TextKit 1 で描く。この方針が効くのは、全体を1つで描くプレビュー（`MarkdownTextPreview`）でマウスを動かす前など、`layoutManager` に触れていない間に限られる。
- TextKit 2 のまま描く場合（`viewWillDraw` を経ずに描いた場合）は、描画の途中で切り替えず、線を描かずに記号の文字をそのまま見せる。
- 範囲選択の色は `drawBackground(in:)` の後に塗られるため、選択した行では線が選択の色の下になる。
- 線の色は、文字列に残っている記号の文字色をそのまま使う。

#### 右から左の文字で始まる引用

段落の向きは既定で最初の強い向きの文字で決まる。ヘブライ語やアラビア語で始まる引用は右から左の段落になり、引用記号が行の右端へ動く。線は1行目の記号の位置から段落の全行へ伸ばすため、折り返した行の文字に重なったり、同じ深さの隣の段落と位置がずれたりしていた。

`aligned` は引用記号を持つ段落の `baseWritingDirection` を `.leftToRight` に固定する。記号は常に左に置かれ、深さが同じなら段落によらず同じ位置になる。本文の中の右から左の文字は、その向きのまま表示される（行は左寄せになる）。

#### 線の求め方

- 線は記号の文字の幅の中央（`│` とその後ろの空白の位置の中間）に、段落のすべての行を通して引く。行間と段落の間隔、折り返した行（記号の文字がない）にも線が続く。
- 引用の最後の段落では、後ろの段落の間隔へはみ出さないよう、文字のある高さ（`lineFragmentUsedRect`）で止める。
- 線が次の段落へ続くかは、次の段落の引用の深さ（段落の先頭の `previewQuotePrefix` の範囲にある `│` の数、`PreviewQuoteBars.barCharacters`）だけで決まる。属性と文字だけから求め、次の段落はレイアウトしない。行の位置を求めるのは、描く範囲（`drawBackground(in:)` の矩形）にかかる段落に限る。以前は次の段落の行まで列挙し、画面外の長い段落もレイアウトしていた。
- 記号ごとに `layoutManager.numberOfGlyphs`（文書全体のグリフを作る）を呼ばない。記号の右端は、記号の後ろの文字のグリフの位置から求める。
- 文字は残るため、`aligned` の位置合わせ、範囲選択、コピーで得る文字列（`│  ` を含む）は変わらない。
- 引用を含む文字列だけ、描画の前（`viewWillDraw`）に `layoutManager` を用意する。

入れ子の引用を含むコールアウトは、リストを含む場合と同じく `Text` ではなく `NSTextView` で描く（`MarkdownPreview.inlineText`）。`Text` は図形を重ねられず、文字の線が行間で途切れるため。`NSTextView` は段落の間隔を反映するため、このコールアウトの段落の間は `Text` で描くコールアウトより広い。

`NSTextView` は右クリックを受け取り、行に付けた SwiftUI の文脈メニュー（「原文へ移動」）を出さない。`inlineText` は引数 `sourceRange` を `HoverLinkText` の `onRevealSource` に渡し、`NSTextView` の文脈メニューに同じ項目を加える。コールアウト、見出し、段落、タスク、表のセルはブロックの `sourceRange` を渡す。ブロックに属さない脚注は渡さない。

PDF・HTMLの書き出しは `MarkdownHTMLExporter` が `<blockquote>` を出力し、引用記号の文字を使わない。iOS版（`MobileMarkdownPreview`）は別の実装で、今回は確かめていない。

## リスト項目の行間がコールアウトの中と外で異なる

行の間隔は、描く部品によって次のように決まる（15ptのシステムフォントでの実測）。

| 描き方 | 行の間隔 |
| --- | --- |
| SwiftUI の `Text` | 約19pt。段落スタイルの `lineSpacing`・`paragraphSpacing` を無視する |
| `NSTextView` の段落の途中の行 | 行の高さ18pt ＋ `lineSpacing` |
| `NSTextView` の段落の最後の行 | 行の高さ18pt ＋ `lineSpacing` ＋ `paragraphSpacing` |
| `NSTextView` の文字列全体の最後の行 | 行の高さ18ptだけ。後ろの間隔は高さに含まれない |

リスト項目の段落スタイルは `lineSpacing` 3・`paragraphSpacing` 4 だった。そのため、コールアウトの中（複数の項目を1つの文字列で描く）と外（項目ごとに1つのビューで描く）で間隔が食い違っていた。項目ごとに `NSTextView` で描く版では中が25pt・外が18pt、すべて `Text` で描いていた版では中が19pt・外が約21ptだった。

- リスト項目の段落スタイルを `lineSpacing` 1（`MarkdownRenderer.listLineSpacing`）・`paragraphSpacing` 0 にした。行の間隔は19ptになり、`Text` で描く段落や、リストを含まないコールアウトとそろう。折り返した行と次の項目の間隔も同じになる。
- 項目ごとに描く `NSTextView` は、最後の行の後ろの間隔を高さに含めない。`PreviewListIndent.trailingSpacing` で求めた分を行の下の余白として補う。

全体を1つの `NSTextView` で描くプレビューと埋め込み文書のリストも、同じ段落スタイルを使うため19ptの間隔になる。

## 検証方法

`PreviewBlockStyleTests` で、実際の `MarkdownPreview` を `NSHostingView` に載せて確かめる。

- 表の罫線とコールアウトの縦線は、`cacheDisplay(in:to:)` で描いた画像のピクセルを調べる。表は背景とのコントラストが1.5以上で縦に続く線を数え、コールアウトは縦線の列が本文の高さの範囲で途切れないことを確かめる。
- `NSTextView` の中の縦線は、`PreviewQuoteBars.bars` の矩形の列のピクセルが途切れないことを、入れ子の引用を含むコールアウト、全体を1つで描くプレビュー、埋め込み文書の文章の部分で確かめる。折り返した行と引用の最後の行の扱いは、矩形の位置で確かめる。
- 記号の文字の隠し方は、`HoverPreviewTextView` の一時属性と、選択を RTF で書き出して読み戻した記号の色（透明でないこと）で確かめる。文字列の変更で付け直すこと、引用のない文字列で TextKit 2 のままであることも確かめる。
- 右から左の引用は、折り返すヘブライ語の引用で、線が深さごとに1つの位置に並び、途切れず、本文のどのグリフの矩形とも重ならないことを確かめる。
- 次の段落をレイアウトしないことは、長い次の段落を持つ文字列で `bars` を呼んだ後の `firstUnlaidCharacterIndex()` で確かめる。
- コールアウトの見出しは `MarkdownCalloutKind.note.title` から組み立てる。直書きすると英語環境で一致しない。
- 「原文へ移動」は、文脈メニューの項目を実行して範囲が渡ることを確かめる（`PreviewListAlignmentTests`）。
- リストの間隔は、コールアウトの中は `NSLayoutManager` の行の位置、外は項目ごとの `NSTextView` の位置から求めて比べる。
- 行の高さを調べるときは、全体を1つで描く経路ではなく構造化プレビューの経路で測る。`MarkdownPreview` は `onRevealSource` などを渡したときに構造化プレビューになる（`PreviewLayoutTestSupport.preview(_:onRevealSource:)`）。
