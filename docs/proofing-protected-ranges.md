# コードブロック内の語にスペルミスの下線が付く問題

[機能ガイドに戻る](features.md)

コードブロックを含む文書を開くと、コード内の語（` ```cpp ` ブロックの `#include <iostream>` の `iostream` など）に赤いスペルミスの下線が付いた。インラインコードの語も同様だった。コードとURLは校正の対象外とする設計で、`MarkdownProofingContext.protectedRanges` がその範囲を返し、共有解析では `DocumentSnapshot.proofingRanges` に同じ範囲を保持している。それでも下線が付いたのは、この範囲が「キャレットの位置」の判定にしか使われていなかったためである。

## 原因

`MarkdownTextEditor.Coordinator.applyProofing` は、キャレットが保護範囲（コード・URL）の中にあるかどうかで `NSTextView` の `isContinuousSpellCheckingEnabled` と `isAutomaticSpellingCorrectionEnabled` を切り替えていた。自動訂正は入力中の語にしか働かないので、キャレット位置で切り替えれば足りる。一方、自動スペルチェックは有効になった時点でテキストビューの表示範囲全体を調べ、編集のたびに編集箇所を調べ直す。キャレットが本文にあると、文書全体の語がチェックされ、保護範囲の中の語にも下線が付く。

ファイルを開いた直後はキャレットが先頭（本文）にあるため、症状が必ず出る。共有解析を使う通常のエディターでは、最初のスナップショットが届くまでチェックを止めている（方言が未確定として扱われる）が、スナップショットが届いてチェックを有効にした瞬間に全体がチェックされるので、解析の待ち合わせは症状に関係しない。保護範囲は正しく計算されており、計算のタイミングではなく、範囲が下線の付与に使われていないことが原因だった。

同じ原因で次の経路も影響を受けていた。

- インラインコードとURL: キャレットが本文にあれば、` `iostreem` ` のようなインラインコードの語にも下線が付く。URLの語は `NSSpellChecker` がリンクとして読み飛ばすため、実際には下線が付かなかった。
- 再読み込み: `updateNSView` は外部から本文が変わると `textView.string` で全文を置き換える。この置き換えで古い保護範囲はすべて無効になり（`MarkdownProofingContext.shifted` が置き換えに切られた範囲を捨てる）、新しいスナップショットが届くまでの間は保護範囲が空のままチェックが走る。
- 解析待ちの間にコードになった語: 本文として下線が付いた語を後からフェンスやバッククォートで囲んでも、下線は残る。

## 修正

- `Coordinator` に `NSTextViewDelegate` の `textView(_:shouldSetSpellingState:range:)` を実装した。スペル・文法の印を付ける範囲が保護範囲と重なる場合は `0` を返し、印を付けない。保護範囲は編集に合わせてずらしたもの（`protectedProofingRanges`）を使う。本文が解析済みのソースから変わっている間は、印を付ける範囲を含む段落のインラインコードとURLも調べる。キャレット位置の判定に使っている `isProtectedInParagraph` と同じ考え方である。
- 新しい解析結果で保護範囲を更新したときは、保護範囲に残っている印を `setSpellingState(0, range:)` で消す。本文として付いた下線を、後からコードになった時点で取り除くためである。印のない範囲は飛ばすので、更新のたびに全範囲を再描画することはない。
- 編集が以前の全文を置き換えた場合（再読み込みや全選択からの貼り付け）は、古い保護範囲から新しい本文のコードの位置はわからない。共有解析では、置き換えた本文に一致するスナップショットが届くまでスペルチェックと自動訂正を止める。スナップショットが届いてチェックを有効にすると、表示範囲が委譲メソッドを通して調べ直される。

キャレットがコード内にある間にスペルチェック全体を止める既存の動作は変えていない。

## 検証

- `MarkdownProofingTests` の次のテストで確認する。いずれもエディターをウインドウに載せ、`checkText(in:types:options:)` でチェックを走らせてから、`NSLayoutManager` の一時属性 `.spellingState` を語ごとに読む。本文の `speling` に印が付くことも確かめ、チェックが実際に走ったことを保証している。
  - `testOpeningWithCaretInProseDoesNotMarkCodeOrURLs`: 共有解析なしで開いた直後。
  - `testSnapshotArrivingAfterOpenDoesNotMarkCodeOrURLs`: 共有解析で、最初のスナップショットが届いた後。
  - `testWordsThatBecomeCodeLoseTheirMarkersWhenTheAnalysisArrives`: 解析待ちの間にフェンスで囲んだ語の下線が、解析の到着で消えること。解析待ちの間に入力したインラインコードに印が付かないこと。
  - `testReloadingTheWholeTextWaitsForItsAnalysisBeforeChecking`: 全文置き換えの後、スナップショットが届くまでチェックを止め、届いた後もコードに印が付かないこと。

  修正を外すと4件とも失敗する。
- 実機では、`./start.sh sample.md` で開いたアプリのアクセシビリティ要素 `AXTextArea` から `AXAttributedStringForRange` で属性付き文字列を取り、`AXMarkedMisspelled`（表示中の下線）が付いた語を列挙した。修正前のビルドでは `speling`・`iostream`・`mian`・`iostreem` に付き、修正後は `speling` だけに付く。同じ文字列の `AXMisspelled` は、アクセシビリティの問い合わせ時に計算される判定で、下線の有無とは関係なくコード内の語にも付くので、確認には使えない。

## 対象外

- 「スペルと文法を表示」パネルや「スペルチェック」（⌘;）で次のスペルミスへ移動する操作は、`NSSpellChecker` が直接語を探して選択するため、この委譲メソッドを通らない。コード内の語で止まる可能性があるが、実機では確かめていない。ユーザーが明示的に始める操作であり、今回は変更していない。
- AIによる推敲は、ユーザーが選択したテキストだけを対象にするため、保護範囲とは別に扱う。
