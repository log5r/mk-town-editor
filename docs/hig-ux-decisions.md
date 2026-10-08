# HIGに沿ったUXの設計判断（#23〜#29、#52）

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

## ツールバー（#23）

ID・名前・シンボル・既定表示の有無を `WorkspaceToolbarItem` にまとめた。既定で表示するのは表示モード、書式（太字・斜体・リンク）、分割配置、別ウインドウのプレビュー、「書き出し・公開」「履歴」「文章ツール」メニューだけ。個別のボタンは「ツールバーをカスタマイズ」から追加できる。`WorkspaceToolbarTests` はシンボルの重複（書式コマンドと表示モードを含む）と、共有を意味する `square.and.arrow.up` の使用を検出する。

## 設定ウインドウ（#52）

`Settings` を `TabView` のタブ（一般・エディタ・プレビュー・校正・スニペット・拡張・キーボード）に分けた。記録したキーのうち、AppKitが私用領域の文字（U+F700〜U+F8FF）で表す矢印・ファンクション・Home/End・Pageキーは割り当てない。⌘←などをメニューに取られると、エディタの標準のカーソル移動ができなくなる。以前の版で保存した割り当てが、後の版でメニューに固定したキー（⌥⌘Rなど）と重なる場合は、固定のメニュー項目を優先する。設定値はバインディングから直接 `EditorSettingsStore` に書き込み、保存ボタンはない。ショートカットは `ShortcutRecorderView` でキー入力を記録して即座に適用する。保存形式は[キーボードショートカットの割り当て方針](keyboard-shortcuts.md#記録したキーの保存形式52)を参照。行番号は `AppEditorSettings.showsLineNumbers` から `EditorLayoutOptions` を通じて `rulersVisible` に反映する。

## 実機での確認方法

ユニットテストに加え、`./start.sh` で起動したアプリをAppleScriptとCGEventで操作して確認した。

- キー入力は `System Events` の `keystroke` / `key code` で送り、エディタのキャレット位置は `AXTextArea` の `AXSelectedTextRange` で読む。
- `System Events` の `click at` は実際のマウスイベントにならず、SwiftUIのタップジェスチャや一覧の選択が反応しない。クリックは `CGEvent(mouseEventSource:mouseType:mouseCursorPosition:mouseButton:)` を `cghidEventTap` へ送る小さなSwiftプログラムで行う。
- 画面の確認は `screencapture -x -R x,y,w,h` でウインドウの範囲だけを撮る。
