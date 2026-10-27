# 文書内のテキスト検索・置換

macOS・iOS・iPadOSで、開いている書類の本文を検索・置換できる。対象はMarkdownの原文で、フロントマターやコードブロックも含む。

## 操作

| プラットフォーム | 検索・置換の開き方 |
| --- | --- |
| macOS | 「編集」の「検索…」（⌘F）または「置換…」（⌘⌥F） |
| iOS・iPadOS | ツールバーの虫眼鏡「検索・置換」、または外付けキーボードの⌘F。検索欄のメニューから置換へ切り替える |

検索欄に文字列を入力し、前後の一致へ移動する。置換欄には新しい文字列を入力し、1件ずつ置換するか、すべて置換する。空の置換文字列で一致箇所を削除できる。変更は通常の書類編集と同じ保存処理に反映され、Undoで取り消せる。

iOS・iPadOSでプレビューだけを表示している場合、検索を開くと編集画面へ切り替わる。検索を閉じても本文は編集画面に表示する。プレビューに切り替えると検索UIを閉じる。

macOS版は[正規表現検索やフォルダ全体の検索・置換](features.md#文書内の移動と検索)にも対応する。これらの拡張機能はモバイル版には含めない。

## 標準UIを使う設計

macOSでは既存の`NSTextView`と`NSTextFinder`、モバイル版では`TextEditor.findNavigator(isPresented:)`を使う。OSが検索結果の表示・移動・置換・Undoを処理するため、別の文字列置換エンジンや編集欄を作らず、既存の本文バインディングを使える。検索UIのラベルと検索オプションはOSが提供する。

モバイル版の表示状態は`MobileEditorState`で管理する。検索要求時は編集欄を表示し、自動配置の設定は維持する。検索中に表示メニュー、画面幅、アクセシビリティの文字サイズ変更で編集欄が隠れた場合も、検索の表示状態を解除する。

新しく生成した`TextEditor`へ同時に検索UIの表示を要求すると、編集欄だけが表示され、検索UIが開かない場合がある。`MobileFindNavigator`は要求を保留し、UIKitの入力欄と検索機能の準備を300ミリ秒待ってから表示する。`Task.yield()`だけでは準備前に再開する場合がある。画面を切り替えると待機タスクがキャンセルされるため、古い要求による再表示も防げる。

プレビュー専用の表示では編集欄を取り除き、フォーカスと検索の表示状態を解除する。幅0の編集欄を残す構成も検証したが、iPad上で検索セッションが終了せずに残る場合があった。編集欄が表示されたままの画面幅変更では、既存の入力欄を維持する。

## 検証

`FindReplaceCommandsTests`はmacOSの標準検索アクションと、入力変換中の一括置換の抑止を確認する。`MobileEditorLayoutTests`は各表示モード・画面幅・アクセシビリティ文字サイズからの検索開始と、プレビューへの切り替え後の検索再開を確認する。

`MobileWorkspaceTests`は実際のSwiftUI編集欄で標準検索が有効になっていることを確認し、日本語・絵文字を含む検索、前後移動、1件置換、空文字列への一括置換、該当なし、Undo、保存後の再読み込みを検証する。

`testFindRequestPresentsNavigatorAfterLeavingPreview`は、プレビューから検索UIが開くことと、プレビューへ戻ると検索UIが閉じ、もう一度開けることを確認する。

検索UIを伴うテストでは、実際の書類画面と同じ`NavigationStack`とツールバー内に編集欄を配置し、`UIHostingController.viewDidAppear`を待ってから操作する。表示・終了の判定も固定時間の待機だけで済ませず、検索UIの表示状態とバインディングの更新を待つ。

テストが取り除かれた`UITextView`を参照している間は、検索セッションや表示状態のフラグが残る場合がある。取り除いた入力欄の`findInteraction`では終了を判定せず、バインディングと画面内の編集欄の有無、`editor.window == nil`を検証する。再表示時は新しい入力欄の`isFindNavigatorVisible`を確認する。

2026-10-27に最新mainを取り込んだ状態で全Swiftテスト1,187件、iPhone Duo（iOS 27.1）とiPad Pro 13インチ（iOS 26.0）のシミュレータ上で各42件、補助スクリプトの71件が成功した。検索・置換メニューへの切り替えと、プレビューから検索を開く操作もDevice Hubで確認した。

## 参照

- [Apple: findNavigator(isPresented:)](https://developer.apple.com/documentation/swiftui/view/findnavigator(ispresented:))
- [Human Interface Guidelines: Searching](https://developer.apple.com/design/human-interface-guidelines/searching)
