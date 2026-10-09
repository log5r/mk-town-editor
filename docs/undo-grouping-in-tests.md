# テストでのUndoグループの区切り方

`MarkdownEditorModelTests.testConsecutiveCommandsUndoIndividually` は、`swift test` では成功するのに、Xcodeでアプリをホストにして実行すると毎回失敗していた（Issue #69）。太字と斜体のコマンドを順に適用したあと、1回目の `undo()` で両方の変更が戻る。アプリ本体には問題がなく、テストがUndoグループを区切る方法が、アプリをホストにした実行環境では機能していなかった。

## 原因

`MarkdownEditorModel` のコマンドは、`shouldChangeText(in:replacementString:)` と `didChangeText()` の間で `NSTextStorage` を書き換える。Undoの登録は `NSTextView` が行い、明示的な `beginUndoGrouping` / `endUndoGrouping` は使わない。`NSUndoManager` は `groupsByEvent` が真のとき、最初の登録で自動的にグループを開き、イベントの終わりにそのグループを閉じる。

旧テストは各コマンドの後に `RunLoop.current.run(until:)` を呼び、ネストしたRunLoopを回すことでグループが閉じると想定していた。2026-10-10に、各段階での `undoManager.groupingLevel` を出力するテストで、2つの実行環境を比べた。

| 段階 | `swift test` | Xcodeホスト |
| --- | --- | --- |
| 太字を適用した直後 | 1 | 1 |
| `RunLoop.current.run(until:)` の後 | 0 | 1 |
| `NSApp.nextEvent(matching:until:inMode:dequeue:)` の後 | 0 | 1 |

`swift test` では `xctest` ツールがテストを呼び出し、`NSApplication` は動いていない。この場合、ネストしたRunLoopの1回でグループが閉じる。

Xcodeホストでは、テストはアプリの `-[NSApplication run]` がイベントを待つ間に、mach portのsource1コールアウト（`__CFMachPortPerform` → `_XCTestMain`）から呼ばれる。テストの実行全体が、外側のイベントループの1サイクルの中に収まる。自動で開いたグループは、ネストしたRunLoopを回しても `nextEvent` を呼んでも閉じず、テストから戻った後に閉じる。そのため、2つのコマンドが1つのグループにまとまる。

自動で開いたグループを、テストから `endUndoGrouping()` で閉じる方法も使えない。`swift test` では、予約済みの閉じる処理が後で走り、対応する `beginUndoGrouping` がないため `NSInternalInconsistencyException` になる。

## 修正

テストのウインドウのデリゲートが、`groupsByEvent` を偽にした専用の `UndoManager` を `windowWillReturnUndoManager(_:)` で返す。各コマンドは `beginUndoGrouping()` と `endUndoGrouping()` で囲み、ツールバーのクリック1回（1イベント）を再現する。RunLoopの状態に依存しないため、どちらの実行環境でも同じ結果になる。コマンドが用意されたグループの外でUndoを登録した場合、`groupsByEvent` が偽の `UndoManager` は例外を投げるので、そのような変更もテストで検出できる。

アプリ本体のコードは変更していない。

## 検証

- `swift test` と、Xcodeホストでの次のコマンドの両方で、`MarkdownEditorModelTests` の41件が成功する。

  ```sh
  xcodebuild test -project MKTownEditor.xcodeproj -scheme MKTownEditor -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:MKTownEditorTests/MarkdownEditorModelTests
  ```

- 実機では、`./start.sh` で起動したアプリに「hello」だけの書類を開き、全選択して太字と斜体を順に適用してから、⌘Zを2回押した。本文は `**_hello_**` → `**hello**` → `hello` と1段階ずつ戻った。キー入力（⌘B・⌘I）でも、ツールバーの「太字」「斜体」ボタン（アクセシビリティの `AXPress`）でも同じ結果になった。操作は `osascript` の `System Events` で自動化し、`AXTextArea` の値を読み取って確認した。

## 同様のテストを書くとき

- 1回のUndoで戻ることだけを確かめるテストは、区切りを作らなくてよい。`groupsByEvent` が真のとき、`undo()` は開いたままの最上位グループを閉じてから戻す。
- 複数のコマンドを別々に戻せることを確かめるテストでは、RunLoopを回してイベントの区切りを作らない。この資料の方法のように、専用の `UndoManager` と明示的なグループで区切る。`PreviewTaskUndoTargetTests` も同じ方法を使っている。
