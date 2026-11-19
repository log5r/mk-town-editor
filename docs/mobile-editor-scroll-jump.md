# iOS版で入力ごとに本文が上下に揺れる問題

iPhone Duoで長い書類の末尾付近を編集すると、1文字入力するたびに本文が上下に揺れた（[issue #84](https://github.com/log5r/mk-town-editor/issues/84)）。日本語入力の変換中も、未確定文字列が変わるたびに同じ揺れが起きた。

## 原因

iOS版の編集欄はSwiftUIの`TextEditor(text:selection:)`だった。`TextEditor`は、バインディングが更新されるたびに本文全体のレイアウトをやり直す。1文字の入力でも、IMEの未確定文字列の更新でもバインディングが更新される。

TextKit 2は、まだレイアウトしていない段落の高さを概算で求める。概算では全段落を折り返しなしの1行として扱うため、折り返しのある長い書類では`contentSize.height`が一時的に縮む。末尾付近を表示していると、縮んだ高さに合わせて`contentOffset.y`が押し戻され、次のレイアウトで元の位置付近へ戻る。この往復が揺れとして見える。

アプリ側の修飾子（フォント、選択範囲のバインディング、`MobileFindNavigator`、`.clipped()`）は原因ではなかった。修飾子のない`TextEditor(text:)`単体でも、折り返す幅では同じ揺れが起きる。

## 調査方法と計測値

iPhone Duoシミュレータ（iOS 27.2）で、約80段落の日本語の書類を使った。各段落は編集欄の幅で2行に折り返す。`NavigationStack`内に実際の`MobileEditorWorkspace`を表示し、`editor.insertText`で1文字ずつ入力した。`contentOffset`と`contentSize`はKVOで記録した。KVOを使うと、次のレイアウトで補正される途中の値も記録できる。

| 条件 | 結果 |
| --- | --- |
| `TextEditor`、編集欄の幅433ポイント | `contentSize.height`が2944→1843→2680と変化。末尾付近の`contentOffset.y`は2716→1438→2275と跳ねた |
| 同上、等幅フォント指定 | 1文字ごとに止まる位置も3198→2508→2024→1980と変わった |
| 修飾子なしの`TextEditor(text:)`、幅433ポイント | 跳ねた |
| `TextEditor`、幅951ポイント（折り返しなし） | 跳ねなかった |
| `UIViewRepresentable`で包んだ`UITextView`、幅433ポイント | TextKit 2・TextKit 1とも、`contentOffset`・`contentSize`が変化しなかった |

最後の`UITextView`は、`updateUIView`では本文が異なる場合だけ代入し、`textViewDidChange`でバインディングを更新する構成で計測した。

## 修正

編集欄を`MobileMarkdownTextView`（`UITextView`を包む`UIViewRepresentable`）に置き換えた。入力した本文はUIKitからバインディングへ書き込む。`updateUIView`では、バインディングの本文が最後に同期した本文と異なる場合だけ`UITextView`へ代入する。入力のたびに本文全体を入れ替えないため、TextKit 2の概算に戻らない。

`TextEditor`で得ていた挙動は次のように引き継いだ。

| 挙動 | 実装 |
| --- | --- |
| 本文のバインディング | 入力・置換・Undoの結果を`textViewDidChange`で反映する。外部から本文が変わった場合だけ`UITextView`へ代入し、選択範囲は新しい本文の長さに収める |
| 日本語入力 | 変換中（`markedTextRange != nil`）は`updateUIView`で本文を代入しない。未確定文字列はバインディングへ書き込まず、確定後に反映する（[macOS版の同じ問題](ime-composition-reset.md)） |
| 選択範囲 | `MobileTextSelection`に保持し、プレビューから戻って編集欄を作り直したときに復元する。キャレット移動のたびに画面全体を再描画しないよう、SwiftUIの状態にはしない |
| Duoの開閉・幅の変更 | 編集欄が表示されたままなら同じ`UITextView`を維持する |
| フォント | `.body`と同じ大きさの等幅システムフォント。SwiftUI環境の`dynamicTypeSize`に追従する。フォントを設定すると本文全体をレイアウトし直すため、文字サイズが変わった場合だけ設定する |
| アクセシビリティ | ラベル「Markdown本文」と識別子`markdownEditor`を`UITextView`に設定する |
| フォーカス | `@FocusState`の代わりに`Bool`のバインディングを使う。プレビューへの切り替え、設定画面を開く操作、編集欄が隠れたときにキーボードを閉じる。編集欄をタップしたときもバインディングへ反映する |
| 検索・置換 | `UITextView.findInteraction`を直接使う（[検索・置換の設計](find-and-replace.md#標準uiを使う設計)） |
| キーボードとセーフエリア | 配置はSwiftUIのセーフエリアとキーボード領域に任せる。`ignoresSafeArea`や`contentInsetAdjustmentBehavior`の変更、画面サイズ・端末種別による分岐は使わない |

`TextEditor`内部の`UITextView`は、セーフエリアやキーボードの下まで広がっていた（テストの計測では、キーボード表示中も画面の下端までの高さがあった）。新しい編集欄はセーフエリアとキーボードの内側に配置される。本文がバーの下へスクロールして透ける表示はなくなると考えられるが、画面上では確認していない。

## 検証

`MobileWorkspaceTests.testTypingNearEndOfLongWrappedDocumentKeepsScrollPositionStable`は、80段落の日本語の書類を実際の`MobileEditorWorkspace`に表示する。Duoの姿勢に依存しないよう、編集欄の幅を360ポイントに固定する。360ポイントは配置判定で使う最小の列幅で、どの姿勢でもセーフエリアに収まる。末尾にキャレットを置いてスクロールが落ち着くのを待ち、編集欄がキーボードより上にあることとキャレットが見えることを確認する。その後、10文字の通常入力と`setMarkedText`による8回の未確定文字列の更新を行う。

KVOで記録した`contentOffset.y`の最小値が開始位置から1行分を超えて戻らないこと、最大値が4行分を超えて進まないこと、`contentSize.height`が4行分を超えて縮まないことを検査する。変換中に未確定文字列が保たれること、確定後の本文がバインディングへ反映されることも確認する。

| 実装 | 結果（2026-11-19、iPhone Duo / iOS 27.2シミュレータ） |
| --- | --- |
| 修正前の`TextEditor` | 失敗。`contentOffset.y`が3165→1448と戻り、`contentSize.height`は1821まで縮んだ |
| `MobileMarkdownTextView` | 成功。`contentOffset.y`は2905→2926と1行分だけ進み、`contentSize.height`の変化は3283への1回だけだった |

修正後は、iPhone Duo（iOS 27.2）シミュレータでモバイルの全48件が成功した。回帰テストは単独でも3回続けて成功した。`swift test --force-resolved-versions`は1,190件を実行し、既存の8件がスキップ、失敗は0件だった。`Tools`のPython検査73件も成功した。

修正前のコードで実行すると、編集欄の位置の検査も失敗する。`TextEditor`内部の`UITextView`がセーフエリアの外まで広がっているためで、揺れとは別の理由による。

`testEditorBridgesFocusSelectionAndOutsideTextChanges`はフォーカスの双方向の反映、プレビューから戻ったときの選択範囲の復元、外部からの本文変更、再描画中の未確定文字列の保持を確認する。`testEditorUsesMonospacedBodyFontThatFollowsDynamicType`は文字サイズの変更で等幅フォントの大きさが変わり、同じ入力欄が維持されることを確認する。

### テストを書くときの注意

- `becomeFirstResponder()`の直後に`setMarkedText`を呼ぶと、キーボードの準備が終わった時点で未確定文字列が破棄される場合がある。入力欄にフォーカスしてから500ミリ秒ほど待って変換を始める。
- フォーカスのバインディングを同じ実行ループの中でtrue→falseと変えると、SwiftUIが変化を検出せず`updateUIView`を呼ばない。テストでは変更の間に待機を入れる。実際の操作では、タップと設定ボタンの押下の間に再描画が入る。
- `insertText`をテストから直接呼んでも、キーボード入力のようにキャレットへの自動スクロールは起きない。入力後にキャレットが見えるかどうかは、この方法では検証できない。
- シミュレータへの合成キーボードイベントでは、キーボード処理が止まる場合があった。入力の検証には`insertText`と`setMarkedText`を使う。

## 未検証の事項

- 実機（iPhone Duo）での入力。修正後の検証はシミュレータだけで行った。
- ソフトウェアキーボードからの実際の入力で、末尾に行が増えたときにキャレットへスクロールすること。UIKit標準の`UITextView`の動作だが、自動テストでは確認していない。
- iOS 18のランタイムでの動作。このMacにはiOS 27.2のシミュレータしかない。`isFindInteractionEnabled`などiOS 16以降のAPIだけを使っている。

## 関連

- [iPhone Duo・iOS版の対応](iphone-duo-support.md)
- [文書内のテキスト検索・置換](find-and-replace.md)
- [日本語入力の変換中に文字が消える問題](ime-composition-reset.md)
