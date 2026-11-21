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

描く単位によって2つの方法を使い分ける。

### 1ブロックずつ描く箇所（構造化プレビューの `blockText`・`taskView`）

- `MarkdownRenderer` は行頭記号（`•  `、`1.  `、タスクの状態）に `NSAttributedString.Key.previewListMarker` を付ける。
- `PreviewIndentedText.make` は描画結果から字下げを取り出し、行頭記号と本文に分ける。本文と記号からは字下げを除く。除かないと、`NSTextView` で描く本文で余白と二重になる。
- `PreviewIndentedLayout` は記号の位置（`markerIndent`）を行の余白、記号の列の幅を `bodyIndent - markerIndent` として配置する。本文の左端は深さだけで決まり、折り返した行と項目の続きの段落（`applyContinuationIndent`）がそろう。字下げの幅は表示倍率に合わせて広げる。
- 記号の列（`PreviewMarkerColumn`）は、列より広い記号（`10.  `、`12345.  ` など）を左へはみ出させ、本文を右へ押さない。続きの段落は別の行のビューで、項目の記号の幅を知らないため、本文の位置を深さだけで決める必要がある。
- タスクのチェックボックスの位置は `block.nestingDepth` から求める（`PreviewIndentedText.taskCheckboxIndent`）。本文が空のタスク（`- [ ]` だけ）は記号を隠すと描画結果が空になり、描画結果からは字下げを読み取れないため。

構造化プレビューの引用は、縦線を行のビュー（`Rectangle`）が引用の深さの数だけ描き、ブロックの描画結果には引用記号を含めない。リストの字下げはブロックの内側に置かれ、縦線は動かない。

### 複数のブロックを1つの文字列で描く箇所（`MarkdownTextPreview`・コールアウト・埋め込み文書）

範囲選択とコピーを保つため、1つの `NSTextView`（`HoverLinkText`）で描き、`PreviewAppKitIndent.aligned` で段落スタイルを整える。項目ごとに `Text` へ分けると、項目をまたいで選択できず、コピーから行頭記号やタスクの状態（`☐ 未完了  `）が落ちる。

- 引用記号（`MarkdownRenderer.quote` が `previewQuotePrefix` を付ける）は行頭に固定し、リストの字下げはその内側に置く。段落スタイルは引用記号ではなく本文側から取る。
- 行頭記号は列の中で左寄せし、列より広ければ左へはみ出させて、本文の左端を `headIndent` に保つ。位置は記号の最後の文字の字間（`kern`）と段落スタイルで調整し、文字は変えない。コピーで得る文字列は描画結果と同じになる。
- はみ出しは12pt（`maximumMarkerOverflow`）までにする。タスクの状態（約53〜66pt）のような広い記号を際限なく左へ出すと、入れ子の子の記号が親の記号とほぼ同じ位置まで戻り、深さが見分けられなくなる。行頭より左にも出せない。収まらない記号では本文を右へずらし、同じ項目の明示的な改行の後の行と続きの段落も同じ位置にそろえる。
- 記号の幅は TextKit（`NSLayoutManager`）で測る。Core Text で直接測ると、`☐` や日本語の代替フォントの選び方が異なり、約13pt ずれた。
- コールアウトは、リストの字下げを含むときだけ `NSTextView` で描く。含まないコールアウトはこれまでどおり `Text` で描く。
- 埋め込み文書の `NSTextView` は行の余白（`lineFragmentPadding`）を0にし、引用の中のコードブロックの縦線（`PreviewQuotedCodeBlock`）と引用記号の位置をそろえる。

### 描画結果の変更

`applyContinuationIndent` は、リスト項目の続きの段落（`nestingDepth` が1以上）だけに付ける。以前は引用の直下の段落（深さ0）にも8ptの字下げを付けていたが、どの表示経路でも効いておらず（`Text` は無視し、`NSTextView` では引用記号の段落スタイルが優先された）、字下げを効かせるようにすると引用の本文だけが8pt右へずれるため。

## 検証方法

`PreviewListIndentTests` と `PreviewListAlignmentTests` で確認する。

- 報告と同じ形の文書（見出し、`#` だけの行、段落、3階層の箇条書き）を、2スペース・4スペース・タブの字下げで解析・描画し、深さごとに記号の位置が増えること、本文に字下げが残らないことを確かめる。
- 番号付きリストと箇条書きを4階層で混在させる。親より2段深く書いた子、タスク、明示的な改行と続きの段落、リンクを含む項目、描画キャッシュ（表示倍率とテーマ）の後も確かめる。
- 実際の `MarkdownPreview` を `NSHostingView` に載せ、`NSTextView` の位置や、`NSLayoutManager` で求めた文字の位置を比べる。リンクを含む項目、コールアウト（リンクなし）、全体を1つで描くプレビューの引用の中のリストで、深い項目ほど右に置かれ、引用記号の位置が変わらないことを確かめる。`Text` で描く項目はビューの階層から位置を取れない。
- `ImageRenderer` で `PreviewIndentedLayout` を白地に描き、最も左の濃い画素の位置を比べる。深い項目ほど右から始まること、折り返した行が本文の左端から始まることを確かめる。記号を白で描くと本文の左端だけを測れ、幅の広い記号の項目と続きの段落の本文がそろうことを確かめられる。`Text` の `foregroundColor` は文字列の属性の色を上書きしないため、記号の文字列の属性で色を変える。
- 埋め込み文書は、`WorkspaceEmbedText` を載せて `selectAll` し、`writeSelection(to:types:)` で専用のペーストボードへ書き出して、行頭記号とタスクの状態を含む文字列になることを確かめる。`NSTextView` は文字列を旧来の種類（`NSStringPboardType`）で書き出すため、`writeSelection(to:type: .string)` は失敗する。

`Text` が段落スタイルの字下げを無視することは、同じ手順で `firstLineHeadIndent` を0と60にした文字列を描き、どちらも同じ位置（x=2）から始まることで確かめた。`PreviewIndentedLayout` の余白を外すと `ImageRenderer` のテストが失敗することも確かめた。レビューで指摘された5件（埋め込み文書の分割、コールアウト、本文が空のタスク、幅の広い記号、引用の縦線）は、修正前のコードで失敗するテストを書いて再現してから直した。

既存の `MarkdownRendererTests.testNestedListAndContinuationAreVisuallyIndented` は描画結果の段落スタイルだけを見ていたため、この不具合を検出できなかった。表示の経路を変えるときは、SwiftUI や `NSTextView` に渡した後の位置を確かめる。

## 未対応の関連事項

- リスト項目の中のコードブロックと表は、構造化プレビューで字下げしない。今回の修正の前から同じで、段落スタイルを使っていないため原因も異なる。
- `NSTextView` で描く箇所では、最上位のタスクの状態（`☐ 未完了  `・`☑ 完了  `）が記号の列より大きく広いため、本文の位置が記号の幅で決まる。完了と未完了の兄弟で本文の左端が約13pt 異なる（修正前と同じ）。構造化プレビューはチェックボックスで描くため影響しない。
- 構造化プレビューでは、リンクや画像を含むブロックを `NSTextView` で描き、行の余白（5pt）の分だけ `Text` で描くブロックより本文が右に寄る。修正前から同じ。
- `HoverLinkText.sizeThatFits` は幅の提案が無限のときにそのまま `NSTextView` の幅にし、「Invalid view geometry: width is infinity」を記録する。修正前から同じで、表示の幅は最終的に有限の提案で決まる。
- `MarkdownAnalysis` のリストの入れ子の判定は、CommonMark と一致しない場合がある。親の項目より字下げが深ければ子とみなし、親の本文の開始位置を見ていない。そのため、次の場合に結果が異なる。
  - `- a` の次の ` - b`（1スペース）は、CommonMark では同じ階層の項目だが、子として扱う。仕様の「項目の字下げはそろっていなくてもよい」例（`- a`・` - b`・`  - c`・`   - d`…がすべて同じリスト）も、階段状の入れ子になる。
  - `1. a` の次の `  - b`（2スペース）は、CommonMark では `a` の本文（3桁目から）に届かないため別のリストになるが、子として扱う。
  - 4スペースで字下げした項目の下に、さらに8スペース深く書いた行は、字下げしたコードブロックとして扱う。CommonMark ではコードブロックは段落を中断できないため、項目の段落の続きの文になる。どちらの場合も入れ子のリストにはならない。

  この判定は編集画面の字下げ・アウトライン・整形でも使うため、今回の修正では変えていない。
- `#` だけの行は CommonMark では空の見出し（`<h1></h1>`）で、プレビューで何も表示されないのは仕様どおり。段落内の改行は既定で空白として表示する（CommonMark のソフト改行）。設定の「本文の改行をそのまま表示」で改行として表示できる（[プレビュー設定の仕様](preview-markdown-settings.md)）。
