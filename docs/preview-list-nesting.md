# プレビューで入れ子のリストが平坦になる問題

分割表示のプレビューで、入れ子の箇条書きがすべて同じ深さに並んでいた。編集画面の色分けや解析結果（`MarkdownBlock.nestingDepth`・`parentID`）は入れ子を正しく持っており、失われていたのは表示の段階だった。

## 原因

`MarkdownRenderer.applyListIndent`・`applyContinuationIndent` は、リスト項目と項目の続きの段落の深さを `NSParagraphStyle` の `firstLineHeadIndent`・`headIndent` で表す。全体を1つの `NSTextView` で描く `MarkdownTextPreview` はこの字下げを反映する。

構造化プレビュー（`MarkdownPreview` の `LazyVStack` の経路）は、ブロックごとの描画結果を `inlineText` で `Text(AttributedString(rendered))` に渡していた。SwiftUI の `Text` は段落スタイルの字下げを無視する。そのため、深さの違う項目がすべて同じ位置から始まっていた。リンクや画像を含む項目だけは `HoverLinkText`（`NSTextView`）で描くため字下げされ、表示が不ぞろいになっていた。

構造化プレビューは、見出し・表・タスク・コードブロックを含む文書と、スクロール同期・テーマ・本文幅を指定したときに使う。分割表示では通常こちらの経路を使うため、ほとんどの文書で症状が出ていた。

同じ原因の経路は次のとおり。

- `MarkdownPreview.blockText`：リスト項目と続きの段落。
- `MarkdownPreview.taskView`：タスク項目。チェックボックスも深さに関係なく左端に並んでいた。
- `MarkdownPreview.calloutContent`：コールアウトはまとめた文字列を `inlineText` で `Text` に渡すため、中の入れ子のリストが平坦になっていた。
- `WorkspaceEmbeddedDocumentView`：`![[文書名]]` の埋め込み。文書全体を1つの `Text` で描くため、同じく字下げが消えていた。

全体を1つの `NSTextView` で描く `MarkdownTextPreview` にも、近い原因の不具合があった。`MarkdownRenderer.quote` は引用の各行の先頭に引用記号（`│  `）を付ける。`NSTextView` は段落スタイルを段落の先頭の文字から取るため、引用の中では引用記号の段落スタイル（字下げなし）が使われ、入れ子のリストがすべて同じ位置に並んでいた。

HTML・PDF・リッチテキストのコピーは `MarkdownHTMLExporter` が `<ul>`・`<ol>` を入れ子で出力し、iOS版は `MobileMarkdownPreview` の深さを `padding` で表すため、影響を受けない（コードの確認による。実機での表示は確かめていない）。スライドと別ウインドウのプレビューは `MarkdownPreview` を使うため、同じ修正で直る。

## 修正

`MarkdownRenderer` は行頭記号（`•  `、`1.  `、タスクの状態）に `NSAttributedString.Key.previewListMarker`、引用記号（`│  `）に `previewQuotePrefix` を付ける。リスト項目と、複数のブロックを1つの文字列で描く箇所は、`NSTextView`（`HoverLinkText`）で描き、`PreviewAppKitIndent.aligned` で段落スタイルを整える。行頭記号と本文を1つの選択面に保ち、項目全体（番号・記号・タスクの状態を含む）を選択・コピーできるようにするため。`Text` に分けると選択が記号と本文の間で切れる。

### `PreviewAppKitIndent.aligned`

- 引用記号は行頭に固定し、リストの字下げはその内側に置く。段落スタイルは引用記号ではなく本文側から取る。
- 行頭記号は列の中で左寄せし、列より広ければ左へはみ出させて、本文の左端を `headIndent` に保つ。位置は記号の最後の文字の字間（`kern`）と段落スタイルで調整し、文字は変えない。コピーで得る文字列は描画結果と同じになる。
- はみ出しは12pt（`maximumMarkerOverflow`）までにする。タスクの状態（約53〜66pt）のような広い記号を際限なく左へ出すと、入れ子の子の記号が親の記号とほぼ同じ位置まで戻り、深さが見分けられなくなる。行頭より左にも出せない。収まらない記号では本文を右へずらし、同じ項目の明示的な改行の後の行と続きの段落も同じ位置にそろえる。
- 記号の幅は TextKit（`NSLayoutManager`）で測る。Core Text で直接測ると、`☐` や日本語の代替フォントの選び方が異なり、約13pt ずれた。
- `indentScale` で字下げを広げられる。構造化プレビューは文字と同じく表示倍率で広げ、全体を1つで描くプレビューは従来どおり広げない。

### 構造化プレビュー（`MarkdownPreview` の `blockText`・`taskView`）

- リスト項目は、項目ごとに1つの `NSTextView` で描く（`aligned` に表示倍率を渡す）。
- 項目の続きの段落は、字下げを除いて（`PreviewListIndent.withoutIndent`）行の余白で字下げする。余白は親の項目の本文の左端（`PreviewAppKitIndent.itemBodyIndent`）にそろえ、幅の広い記号で本文が右へずれた項目でもそろう。親は `PreviewLayoutIndex.parent(of:)` で引く。
- タスクはチェックボックスを `block.nestingDepth` から求めた位置（`PreviewListIndent.taskCheckboxIndent`）に置く。本文が空のタスク（`- [ ]` だけ）は描画結果が空になり、字下げを読み取れないため。番号付きのタスクの番号と本文は、字下げを除いた1つの文字列として描く。チェックボックスは操作部品のため別のビューになる。
- `NSTextView` は右クリックを受け取り、行に付けた SwiftUI の文脈メニュー（「原文へ移動」）を出さない。`HoverPreviewTextView.menu(for:)` が、自身の文脈メニューの先頭に「原文へ移動」を加える。リンクを含むブロックも同じ扱いになる。
- 引用は、縦線を行のビュー（`Rectangle`）が引用の深さの数だけ描き、ブロックの描画結果には引用記号を含めない。リストの字下げはブロックの内側に置かれ、縦線は動かない。

### 複数のブロックを1つの文字列で描く箇所

- `MarkdownTextPreview`（全体を1つの `NSTextView` で描くプレビュー）は `aligned` を通す。
- コールアウトは、リストの字下げを含むときだけ `NSTextView` で描く。含まないコールアウトはこれまでどおり `Text` で描く。
- 埋め込み文書は、文章の部分ごとに1つの `NSTextView`（`WorkspaceEmbedText`）で描く。項目をまたいだ範囲選択と、行頭記号・タスクの状態を含むコピーを保つ。

`HoverLinkText` は行の余白（`lineFragmentPadding`）を持たない。`Text` で描く周りの段落、引用の中のコードブロックの縦線（`PreviewQuotedCodeBlock`）と左端がそろう。

### 表示の重さ

リスト項目の数だけ `NSTextView` ができるため、`MarkdownPreview` を `NSHostingView` に載せて実測した（幅700・高さ800の窓、深さ0〜2の箇条書き、最初のレイアウトと400pt ずつ40回のスクロールの合計、5回）。

| 項目数 | main（字下げの修正前） | 記号と本文を別のビューに分けた版 | 項目ごとに `NSTextView`（現在） |
| --- | --- | --- | --- |
| 600 | 最初 7〜12ms、スクロール 386〜408ms | 10〜16ms、615〜640ms | 5〜11ms、418〜488ms |
| 2000 | 7〜13ms、555〜591ms | 10〜12ms、949〜1036ms | 5〜9ms、773〜996ms |

最初の表示は `LazyVStack` が見える行だけを作るため変わらない。スクロールは main より、平均で600項目で約15%、2000項目で約50%（各回では約30〜80%）重いが、記号と本文を別のビューに分けた版より軽い。生きている `NSTextView` は、スクロールし終えた時点で600項目で138個、2000項目で223個だった。

`NSTextView` を TextKit 1 で作る（`init(usingTextLayoutManager: false)`）と、同じ測定で600項目のスクロールが512〜1394ms、2000項目で2631〜5522ms と大きく悪化し、回を重ねるほど遅くなった。既定の作り方のままにしている。

### 描画結果の変更

`applyContinuationIndent` は、リスト項目の続きの段落（`nestingDepth` が1以上）だけに付ける。以前は引用の直下の段落（深さ0）にも8ptの字下げを付けていたが、どの表示経路でも効いておらず（`Text` は無視し、`NSTextView` では引用記号の段落スタイルが優先された）、字下げを効かせるようにすると引用の本文だけが8pt右へずれるため。

## 検証方法

`PreviewListIndentTests` と `PreviewListAlignmentTests` で確認する。

測定の補助は `PreviewLayoutTestSupport` にまとめている。

- 実際の `MarkdownPreview` を `NSHostingView` に載せ、`NSTextView` の位置と、`NSLayoutManager` で求めた文字の位置を比べる。リスト項目はすべて `NSTextView` で描くため、リンクのない項目も測れる。続きの段落は、リンクを含めて `NSTextView` で描かせて測る。`Text` で描くブロックはビューの階層から位置を取れない。
- 報告と同じ形の文書（見出し、`#` だけの行、段落、3階層の箇条書き）を、2スペース・4スペース・タブの字下げで描き、深さごとに記号の位置が増えることを確かめる。番号付きリストと箇条書きの4階層の混在、親より2段深く書いた子、表示倍率、明示的な改行と続きの段落、幅の広い番号（`10.`・`12345.`）と続きの段落、コールアウト（リンクなし）、引用の中のリストも確かめる。
- 選択とコピーは、`NSTextView` を `selectAll` し、`writeSelection(to:types:)` で専用のペーストボードへ書き出して確かめる。構造化プレビューのリスト項目は番号・記号を含む項目全体、埋め込み文書は項目をまたいだ区間全体（タスクの状態を含む）になる。`NSTextView` は文字列を旧来の種類（`NSStringPboardType`）で書き出すため、`writeSelection(to:type: .string)` は失敗する。
- 文脈メニューは、右クリックの `NSEvent` を作って `menu(for:)` を呼び、先頭の「原文へ移動」を実行して、項目の原文の範囲が渡ることを確かめる。
- 折り返した行は、`enumerateLineFragments` で各行の先頭の文字の位置を求め、2行目以降が本文の左端から始まることを確かめる。

`Text` が段落スタイルの字下げを無視することは、`ImageRenderer` で `firstLineHeadIndent` を0と60にした文字列を描き、どちらも同じ位置（x=2）から始まることで確かめた。レビューで指摘された各件（埋め込み文書の分割、コールアウト、本文が空のタスク、幅の広い記号、引用の縦線、構造化プレビューで項目全体を選択・コピーできない）は、修正前のコードで失敗するテストを書いて再現してから直した。最後の件は、main では項目全体が1つのビュー（リンクがあれば `NSTextView` の `1.  alpha`）だったのに対し、記号と本文を分けた版では `NSTextView` が本文（`alpha`）だけを持つことでも確かめた。

既存の `MarkdownRendererTests.testNestedListAndContinuationAreVisuallyIndented` は描画結果の段落スタイルだけを見ていたため、この不具合を検出できなかった。表示の経路を変えるときは、SwiftUI や `NSTextView` に渡した後の位置を確かめる。

## 未対応の関連事項

- リスト項目の中のコードブロックと表は、構造化プレビューで字下げしない。今回の修正の前から同じで、段落スタイルを使っていないため原因も異なる。
- `NSTextView` で描く箇所では、最上位のタスクの状態（`☐ 未完了  `・`☑ 完了  `）が記号の列より大きく広いため、本文の位置が記号の幅で決まる。完了と未完了の兄弟で本文の左端が約13pt 異なる（修正前と同じ）。構造化プレビューはチェックボックスで描くため影響しない。
- 構造化プレビューでは、リスト項目の VoiceOver の読み上げが `Text`（静的テキスト）から `NSTextView`（テキスト領域）に変わる。読み上げは確かめていない。
- `HoverLinkText.sizeThatFits` は幅の提案が無限のときにそのまま `NSTextView` の幅にし、「Invalid view geometry: width is infinity」を記録する。修正前から同じで、表示の幅は最終的に有限の提案で決まる。
- `MarkdownAnalysis` のリストの入れ子の判定は、CommonMark と一致しない場合がある。親の項目より字下げが深ければ子とみなし、親の本文の開始位置を見ていない。そのため、次の場合に結果が異なる。
  - `- a` の次の ` - b`（1スペース）は、CommonMark では同じ階層の項目だが、子として扱う。仕様の「項目の字下げはそろっていなくてもよい」例（`- a`・` - b`・`  - c`・`   - d`…がすべて同じリスト）も、階段状の入れ子になる。
  - `1. a` の次の `  - b`（2スペース）は、CommonMark では `a` の本文（3桁目から）に届かないため別のリストになるが、子として扱う。
  - 4スペースで字下げした項目の下に、さらに8スペース深く書いた行は、字下げしたコードブロックとして扱う。CommonMark ではコードブロックは段落を中断できないため、項目の段落の続きの文になる。どちらの場合も入れ子のリストにはならない。

  この判定は編集画面の字下げ・アウトライン・整形でも使うため、今回の修正では変えていない。
- `#` だけの行は CommonMark では空の見出し（`<h1></h1>`）で、プレビューで何も表示されないのは仕様どおり。段落内の改行は既定で空白として表示する（CommonMark のソフト改行）。設定の「本文の改行をそのまま表示」で改行として表示できる（[プレビュー設定の仕様](preview-markdown-settings.md)）。
