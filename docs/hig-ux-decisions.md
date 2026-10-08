# HIGに沿ったUXの設計判断（#23〜#29、#52、#60〜#62）

Human Interface Guidelinesから外れていたUXを2026-10に直した。各項目の判断、採らなかった案、確認方法をまとめる。

## 新規書類と案内文（#28）

`MarkdownDocument()` は空の本文で始まる。案内文は `EditorTextView.placeholder` として描画するだけで、本文・保存内容・コピー・Undoに入らない。IMEの未確定文字列がある間は描画しない。VoiceOverには `accessibilityPlaceholderValue` で伝える。テンプレートはワークスペースの新規作成シートから選ぶ。

## プレビューの自動更新（#24）

自動更新中は何も表示しない。一時停止中だけ「プレビューは一時停止中 — 最新／未反映の変更あり」と「更新」「再開」を表示する。内部の世代番号は表示しない。切り替えは「表示」メニュー（⌥⌘R、予約リストに追加済み）とツールバーのカスタマイズ項目から行う。別ウインドウのプレビューは `NSWindow` に載せたビューでSwiftUIのシーンではないため、メニューの操作が届かない。そのウインドウには右上に一時停止ボタンを置く。

## シート・パネル・エラー表示（#29）

- 主操作のボタンに `.keyboardShortcut(.defaultAction)` を付ける（正規表現検索の「次を検索」など）。
- 名前変更・移動は1段階にした。「適用」でリンク更新の計画を作り、更新するリンク・確認から外れた書類・上限超過がなければそのまま適用する。確認すべき内容があるときだけ一覧を出して2回目の「適用」を待つ（`WorkspaceFileOperationSheet.appliesWithoutReview`）。
- ファイルパネルは `NSSavePanel.beginAttached` でウインドウのシートとして出す。ウインドウがなければモードレスのパネルにする。サービスメニューの保存（`MarkdownSelectionService`）だけは、エラーを返すポインタが処理の終了までしか有効でないため `runModal()` のままにした。
- ワークスペースのエラーは `WorkspacePresentedError` 1つと `.alert(_:isPresented:presenting:)` 1つで表示する。複数の `String?` を個別のアラートに結ぶと、同時に真になったときに片方が出ない。
- エラーは `WorkspaceErrorQueue.present` で出す（#61）。表示中に別のエラーが起きたら上書きせず待ち行列に入れ、OKで閉じた後に次を出す。同じエラーは1回だけ並べる。閉じてから `advance()` までの間は何も表示していないが、待っているエラーがあれば新しいエラーはその後ろに並べ、起きた順を保つ。上書きにすると、先に起きたエラーを読む前に消えてしまう。閉じた直後に次のエラーを同じ実行ループで設定すると新しいアラートとして出ないおそれがあるため、`advance()` は `DispatchQueue.main.async` で呼ぶ。閉じる処理は `isPresented` のバインディングの1経路だけにし、OKボタンのアクションは空にした。ボタンとバインディングの両方で閉じると、2回目の呼び出しが遅れたときに次のエラーを表示前に消してしまう。
- 「フォルダを記憶できません」（`WorkspaceStore.errorMessage`）も同じアラートで出す（#61）。ストアはすべての書類ウインドウで共有しているので、キーウインドウ（`controlActiveState == .key`）だけがメッセージを受け取り、`clearError()` で消してから待ち行列に入れる。キーウインドウがないときに起きたエラーは、書類ウインドウがキーになった時点で受け取る（`onChange(of: controlActiveState)`）。`controlActiveState` は `WorkspaceStoreErrorReceiver` だけで読み、ウインドウを切り替えるたびに `EditorWorkspace` 全体を再評価しないようにした。
- TSV・CSVの変換失敗のような回復可能な失敗は、`MarkdownEditorModel.showNotice` で数秒間のバナーとVoiceOverのアナウンスにする。

## 分割の仕切り（#25）

`HSplitView` は仕切り位置をバインディングで渡せず、書類ごと・名前付きレイアウトごとに保存した比率を復元できない。そのため比率はSwiftUIの状態のまま、仕切りだけをAppKitの `SplitDividerHandleView` にした。カーソル矩形によるリサイズカーソル、ドラッグ中の強調、ダブルクリックで0.5に戻す操作、`NSAccessibility.Role.splitter` と増減操作を持つ。比率の計算は `EditorSplitSizing.draggedRatio` にまとめ、編集領域が後ろにある配置では符号を反転する。

## 一覧の選択（#26）

サイドバーとパレット系シートの一覧は `List(selection:)` にした。

- 矢印キーは選択を動かすだけ。アウトラインは選択した見出しへ本文を移動するが、フォーカスは一覧に残す（`navigate(to:focusesEditor: false)`）。連続したプレビューは「戻る」の履歴に1件だけ記録する（`NavigationHistory.recordPreview`）。見出しを10個送っても、「戻る」は送り始める前の位置へ1回で戻る。連続かどうかは、起点が直前のプレビュー先と同じかで判定する。途中でエディタのキャレットを動かすと、次のプレビューは新しい連続移動として起点を記録する。
- クリックは行の `activatesOnClick`（`simultaneousGesture` のタップ）で確定する。選択済みの行をもう一度クリックした場合も動く。選択のバインディングはクリックによる変更を無視し、二重に実行しない（`ListKeyboardSelection.isPointerEvent`）。
- Returnは `.contextMenu(forSelectionType:menu:primaryAction:)` の `primaryAction` で確定する。`primaryAction` はダブルクリックでも呼ばれ、タップジェスチャもクリックごとに発火する。このため `primaryAction` はキーボード操作のときだけ実行し（`ListKeyboardSelection.isKeyboardActivation`）、タップは1回目のクリックだけで実行する（`isSingleClick`）。これがないと、ダブルクリックで添付ファイルが2〜3回開く。閉じかけのシートに2回目のクリックが届くことに備えて、パレットには `didSubmit` のガードも置く。右クリックメニューも同じ修飾子に移した。行ごとの `.contextMenu` と併用しない。
- パレット系シートは検索欄にフォーカスを置いたまま `.movesListSelection` の↑↓で選択を動かし、Returnで選択中の候補を開く。候補がなくなったら先頭を選ぶ（`ListKeyboardSelection.resolved`）。
- サイドバーの切り替えは日本語名が省略されないようアイコンにし、名前はツールチップとVoiceOverのラベルにした。

### 結果系シートとインスペクタ（#60）

#26 で残った一覧も `List(selection:)` にした。行の役割で2つの形に分けた。

- 結果へ移動する一覧（プレビュー内検索、フォルダ全体の検索、バックリンク、タグの書類、リンクグラフの書類、タスク、名前付きレイアウト、リンク診断・Markdownの確認・用語の表記、インスペクタの項目）は、クリック（`activatesOnClick`）とReturnで確定する。Returnは共通の `.activatesSelectionOnReturn(_:perform:)` にまとめた。中身は #26 と同じく、`primaryAction` をキーボード操作のときだけ実行する。
- 選択した行を右側に表示する一覧（Gitの履歴・変更ファイル、明示スナップショット）は、選択そのものが操作になる。矢印キーで送るたびに右側が切り替わり、Returnでの確定は置かない。Gitの差分・過去の版とスナップショットの本文は、選択が変わると前の読み込みを取り消し、120ミリ秒待ってから読む。矢印キーを押し続けても行ごとにgitのプロセスやディスクの読み込みを始めず、離れた行の結果やエラーも表示しない。正規表現検索の一致も、選ぶとエディタの該当箇所を選択する。検索パターン欄の↑↓（`.movesListSelection`）でも送れる。この一覧は最初は何も選択しないので、`startsUnselected: true` で↓が1件目、↑が最後を選ぶようにした（パレットは未選択を先頭とみなすため、↓で2件目になる）。
- インスペクタはアウトラインと同じく、矢印キーでは本文を移動してもフォーカスを一覧に残し、クリックとReturnでエディタへ移る。「プロパティを編集…」などの操作はボタンのままにした。タスクの「完了にする」、レイアウトの削除、用語の「移動」「置換」も行内のボタンとして残す。
- 行を開くと閉じるシート（フォルダ全体の検索、バックリンク、タグ、リンクグラフ、タスク、名前付きレイアウト、リンク診断、Markdownの確認、用語の表記）は、パレットの `didSubmit` と同じく、閉じかけのシートに届いた2回目のクリックやReturnを無視する。タグの切り替えやリンクグラフの表示範囲の切り替えでは、一覧から消えた行の選択を外す。
- プレビュー内検索とフォルダ全体の検索の検索欄は改行を入力できる `TextEditor` なので、↑↓はキャレット移動に残し `.movesListSelection` を付けない。結果へはTabで移る。
- 一覧にフォーカスがあるときのReturnは、シートの既定ボタン（プレビュー内検索の「次へ」など）より一覧の `primaryAction` が先に受け取る。実機で、4件の一致の4件目を↓で選んでReturnを押すと4件目へ移動し、続けて「次へ」で1件目へ折り返すことで確かめた（既定ボタンが受け取っていれば、Returnで1件目か2件目へ移る）。

## ツールバー（#23）

ID・名前・シンボル・既定表示の有無を `WorkspaceToolbarItem` にまとめた。既定で表示するのは表示モード、書式（太字・斜体・リンク）、分割配置、別ウインドウのプレビュー、「書き出し・公開」「履歴」「文章ツール」メニューだけ。個別のボタンは「ツールバーをカスタマイズ」から追加できる。`WorkspaceToolbarTests` はシンボルの重複（書式コマンドと表示モードを含む）と、共有を意味する `square.and.arrow.up` の使用を検出する。

## 設定ウインドウ（#52）

`Settings` を `TabView` のタブ（一般・エディタ・プレビュー・校正・スニペット・拡張・キーボード）に分けた。記録したキーのうち、AppKitが私用領域の文字（U+F700〜U+F8FF）で表す矢印・ファンクション・Home/End・Pageキーは割り当てない。⌘←などをメニューに取られると、エディタの標準のカーソル移動ができなくなる。以前の版で保存した割り当てが、後の版でメニューに固定したキー（⌥⌘Rなど）と重なる場合は、固定のメニュー項目を優先する。設定値はバインディングから直接 `EditorSettingsStore` に書き込み、保存ボタンはない。ショートカットは `ShortcutRecorderView` でキー入力を記録して適用する。保存形式は[キーボードショートカットの割り当て方針](keyboard-shortcuts.md#記録したキーの保存形式52)を参照。行番号は `AppEditorSettings.showsLineNumbers` から `EditorLayoutOptions` を通じて `rulersVisible` に反映する。

### ショートカットの記録（#62）

押した組み合わせは `pendingChord` に保留し、すべての修飾キーを離した時点（`flagsChanged`）で適用する。修飾キーのないキーは `keyUp` で適用する。AppKitは⌘を押している間のキーの `keyUp` を送らないため、`keyUp` だけに頼ると⌘の組み合わせが確定しない。修飾キーを押したまま別のキーを押すと保留中の組み合わせを置き換えるので、押し間違いを離す前に直せる。記録中は押している修飾キーを「⌥⌘…」のように表示し、VoiceOverには `accessibilityValue` で伝える。Esc・Delete・修飾キーなしのTabは押した時点で処理する。離す前に欄からフォーカスが外れたら、保留中の組み合わせは捨てる。修飾キーを押したまま別のウインドウやアプリへ移ると、離したときの `flagsChanged` が届かない。そのためウインドウがキーでなくなった時点（`NSWindow.didResignKeyNotification`）でも捨て、後で無関係なキーを離したときに古い組み合わせを適用しないようにした。記録を始めた時点で押している修飾キーは `NSEvent.modifierFlags` から読む。

## 実機での確認方法

ユニットテストに加え、`./start.sh` で起動したアプリをAppleScriptとCGEventで操作して確認した。

- キー入力は `System Events` の `keystroke` / `key code` で送り、エディタのキャレット位置は `AXTextArea` の `AXSelectedTextRange` で読む。
- `System Events` の `click at` は実際のマウスイベントにならず、SwiftUIのタップジェスチャや一覧の選択が反応しない。クリックは `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` を `cghidEventTap` へ送る小さなSwiftプログラムで行う。
- 画面の確認は `screencapture -x -R x,y,w,h` でウインドウの範囲だけを撮る。
- 入力ソースが日本語入力のとき、`keystroke "foo"` は未確定文字列になる。検索欄の文字は `set value of text area ... to "foo"` で設定すると、SwiftUIのバインディングにも反映される。一覧の行の選択状態は `selected of every row of outline 1 of ...` で読める。
- 同時に起きたエラーの待ち行列（#61）は、一時的に2件のエラーを起動時に出すコードを入れて確認した。1件目をReturnで閉じると2件目が新しいアラートとして表示され、2件目をOKボタンのクリックで閉じるとシートが残らないことを `count of sheets` で確かめた。
