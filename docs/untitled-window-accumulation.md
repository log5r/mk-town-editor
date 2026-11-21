# 起動のたびに名称未設定ウインドウが増える問題

macOS版を終了して起動し直すたびに、何も書いていない名称未設定のウインドウが1枚ずつ増えていた。2026-11-21に、バンドルIDだけを変えた実験用のコピーで再現し、原因を特定して修正した。確認したのはmacOS 27.2.1。

## 原因

次の2つが重なっていた。

- 何も書いていない名称未設定の書類ウインドウも、状態復元で戻っていた。
- SwiftUIの `DocumentGroup` は、ウインドウが復元された起動でも、新しい名称未設定の書類を必ず1つ開く。

前回の空ウインドウN枚が戻り、そこに新規の1枚が加わってN+1枚になる。次の起動ではN+1枚が戻るので、起動ごとに1枚ずつ増える。

起動時の書類生成を `Thread.callStackSymbols` で調べると、2つは別の経路で作られていた。

- 新規の名称未設定: `SwiftUI.AppDelegate.applicationDidFinishLaunching` → `SwiftUI.AppWindowsController.showInitial()` → `PlatformDocument` の初期化 → `DocumentGroup(newDocument:)` のクロージャ。ウインドウが復元された起動でも呼ばれる。
- 復元された空のウインドウ: `-[NSApplication _reopenWindowsAsNecessaryIncludingRestorableState:...]` → `NSPersistentUIRestorer` → `+[NSDocumentController restoreWindowWithIdentifier:state:completionHandler:]` → `_restorePersistentDocumentWithState:` → `openUntitledDocumentAndDisplay:error:` → `makeUntitledDocumentOfType:error:`。自動保存がない名称未設定は、空の書類として作り直される。
- 自動保存済みの名称未設定は、`makeDocumentForURL:withContentsOfURL:...` で、バックグラウンドのキューから非同期に読み込まれる。

## 再現の条件

ウインドウ数は、`CGWindowListCopyWindowInfo` で対象プロセスの layer 0 の画面上ウインドウを数えた。起動後7秒待ってから数えた。

| 条件 | 起動ごとのウインドウ数（修正前） |
| --- | --- |
| 既定設定、無編集、正常終了 | 1, 1, 1, 1, 1 |
| `-NSQuitAlwaysKeepsWindows YES`、無編集、正常終了 | 1, 2, 3, 4, 5 |
| 既定設定、無編集、`kill -9`・`NSRunningApplication.forceTerminate`・`kill -TERM` | 毎回1 |
| 名称未設定に入力して自動保存が済んだあと `kill -9` | 自動保存が済むたびに1枚増える。入力しなければ横ばい |
| 起動方法の違い（`open -a`、実行ファイルの直接実行、`open -n`） | 増え方は同じ |

- **経路A**: 「アプリを終了するときにウインドウを閉じる」がオフ（`NSQuitAlwaysKeepsWindows` が真）のまま正常終了すると、次の起動でウインドウ状態が復元される。既定設定で起動しても、前回の終了時に記録された状態は復元される。
- **経路B**: 強制終了の前に自動保存が済んだ名称未設定は、次の起動で戻る。未保存の内容を守る正しい動作なので変えていない。戻る仕組みは2通り見つかった。ウインドウ状態がない場合は `-[NSDocumentController _autoreopenDocumentsFromRecords:...]`、ある場合はウインドウ状態の復元。
- `install.sh` は起動中のアプリを強制終了してから入れ替える。強制終了だけでは、無編集のウインドウは増えなかった。

## 効かなかった方法

アプリデリゲート（`ExternalDocumentOpenAppDelegate`）に `applicationShouldOpenUntitledFile(_:)` を実装し、書類が1つ以上開いていれば `false` を返す方法を試した。一度も呼ばれなかった。

- `NSApp.delegate` の実体は `SwiftUI.AppDelegate` だった。このクラスは `applicationShouldOpenUntitledFile:`、`applicationOpenUntitledFile:`、`applicationShouldHandleReopen:hasVisibleWindows:` を自分で実装していて、`NSApplicationDelegateAdaptor` で渡したデリゲートへ転送しない。`applicationWillFinishLaunching` と `applicationDidFinishLaunching` は転送される。
- 新規の名称未設定は、アプリのデリゲートの `applicationDidFinishLaunching` より前に作られている。その時点で書類数はすでに1以上だった。

## 修正

本文が空の名称未設定の書類ウインドウは、状態復元の対象から外す（`NSWindow.isRestorable = false`）。保存済みの書類と、本文が1文字でもある名称未設定は、これまでどおり復元する。

- 判定は `EditorWindowRestoration.isRestorable(fileURL:isTextEmpty:)`（`Sources/MKTownEditor/EditorWindowRestoration.swift`）にまとめた。
- `EditorWorkspace` の `body` で、背景に置いた `WindowRestorationSetter`（`NSViewRepresentable`）がウインドウへ値を反映する。反映するのは、ビューがウインドウに載った時点と、値が変わった時点。入力すると真、全部消すと偽、保存して `fileURL` が付くと真になる。
- ウインドウへ渡すのは `document.text.isEmpty` の真偽値だけなので、入力のたびに本文全体を比べることはない。
- 起動時に新しい名称未設定を1つ開くSwiftUIの動作と、状態復元そのものは変えていない。

## 検証

`EditorWindowRestorationTests` で次を確認する。

- 判定: 名称未設定で空なら復元しない。名称未設定で本文があれば復元する。保存済みなら空でも復元する。
- `WindowRestorationSetter` が、ウインドウに載った時点と値が変わった時点で `isRestorable` を変えること。
- 実際の `EditorWorkspace` をウインドウに載せたとき、本文の入力と削除、`fileURL` の付与に `isRestorable` が追従すること。修正を外すと、このテストは失敗する。

実験用のコピーでのウインドウ数（修正後、2026-11-21）:

| 条件 | 起動ごとのウインドウ数 |
| --- | --- |
| 既定設定、無編集、正常終了 | 1, 1, 1, 1 |
| `-NSQuitAlwaysKeepsWindows YES`、無編集、正常終了 | 1, 1, 1, 1, 1 |
| 同上で、名称未設定に入力し、自動保存の完了を確かめて正常終了。その後は無編集 | 1, 2, 2, 2, 2（入力した書類が内容ごと戻り、新規の1枚が加わる） |
| 同上で、保存済みの `.md` を開いて正常終了。その後は無編集 | 2, 2, 2, 2, 2（保存済みの書類と新規の1枚） |
| 既定設定、無編集、`kill -9` | 1, 1, 1, 1 |
| `-NSQuitAlwaysKeepsWindows YES`、無編集、`kill -9` | 1, 1, 1, 1 |

- 終了直前（`NSApplication.willTerminateNotification`）にも、空の名称未設定ウインドウの `isRestorable` は偽のままだった。SwiftUIが真に戻すことはなかった。
- 別ウインドウのプレビュー（`DetachedPreviewManager`）を開いたまま `-NSQuitAlwaysKeepsWindows YES` で終了しても、プレビューのウインドウは戻らなかった。`restorationClass` を持たない `NSWindow` だからと見られる。スライド表示のウインドウも同じ作り方。

## 残る挙動

- ウインドウが復元された起動でも、新しい名称未設定が1つ開く。起動時に保存済みのファイルを `open -a` で渡した場合も同じだった。この新規の書類は空なので次回には戻らず、増え続けることはない。
- 修正前に記録された状態に空のウインドウが含まれていると、`kill -9` を繰り返しても、そのウインドウは戻り続ける。枚数は増えない。正常終了すれば状態が書き直される。
- `NSToolbar Configuration mktown-editor-<UUID>` は、名称未設定のウインドウを開くたびに `UserDefaults` に1件ずつ増える（`EditorToolbarInstanceID`）。この修正の対象外。

## 調べ方

- このOSでは、状態復元の保存先が `~/Library/Saved Application State` ではない。`talagentd` の XPC サービス `com.apple.appkit.restoration_storage` が管理していて、ディスク上のパスはログでも `<private>` になる。`~/Library/Autosave Information` は、端末からは TCC で一覧できなかった。
- 状態の有無はアプリのログで判定する。

  ```sh
  /usr/bin/log show --last 5m --style compact --info --debug --predicate 'processID == <PID>' \
    | grep -E 'hasPersistentStateToRestore|restoreWindowWithIdentifier|_autoreopenDocumentsFromRecords|_setShouldRestoreStateOnNextLaunch|discardAllPersistentState'
  ```

  - `hasPersistentStateToRestore=1` なら、ウインドウ状態が復元される。`restoreWindowWithIdentifier` の行数が、復元したウインドウの数になる。
  - `_setShouldRestoreStateOnNextLaunch: shouldRestore=0` と `discardAllPersistentStateAndClose` は、正常終了で状態が捨てられたことを示す。
  - 自動保存の予約と完了は、`Autosaving: proposing to schedule autosave` と `autosave seems to have completed successfully` で確かめる。
- zsh では `log` がシェルの組み込みコマンドなので、`/usr/bin/log` と書く。
- 統合ログのプロセス名（`process ==`）は当てにならない。同じビルドの実行ファイルは同じイメージUUIDを持つため、名前やバンドルIDを変えたコピーが、別のコピーの名前で表示されることがあった。`processID ==` で絞り込む。
- 実験は、バンドルIDを変えたコピーで行う。本物の状態を汚さずに済む。`Tools/make-app-bundle.sh` の `bundle_identifier` を書き換えて組み立て、本物と競合しないよう `CFBundleURLTypes` と `NSServices` を外し、アドホック署名し直す。
