# SwiftUIのビルドエラーとタスクローカル値のactor指定

`./start.sh` が実行するリリースビルドで、`EditorWorkspace.swift` の型チェックの時間超過、`MarkdownCommands.swift` の `extra argument in call`、`MarkdownRenderer.swift` の `@TaskLocal` 展開によるactor分離エラーが発生した。

## 原因と修正

- `EditorWorkspace` の長い修飾子チェーンは、末尾の `focusedSceneValue` や `onDisappear` で型チェックが時間超過した。ナビゲーション、コマンド用の値、ライフサイクル、文書変更の監視を `some View` を返す計算プロパティに分ける。修飾子の順序とコールバックの内容は維持する。
- 式の分割後、カスタマイズ可能なツールバー内の `ForEach` が `ToolbarContent` / `CustomizableToolbarContent` に適合しないことが判明した。`EditorFormattingToolbar` に各 `ToolbarItem` を明示的に宣言し、既存の順序・ID・既定の表示項目・選択範囲の監視を維持する。
- `CommandsBuilder` は1ブロックの直接の要素を最大10個まで受け取る（`ToolbarContentBuilder` のカスタマイズ可能な項目も同様）。11個目のMarkdownメニューを追加すると `extra argument in call` になる。文書用と編集用に分け、各計算プロパティに `@CommandsBuilder` を指定してから `body` で結合する。メニューの順序・内容・ショートカットは維持する。
- `@MainActor` の `MarkdownRenderer` に `@TaskLocal nonisolated` を指定すると、非分離のgetterからマクロが生成するmain actor上の保存領域へアクセスしてしまう。利用箇所はプレビュー・レンダリング・そのテストのmain actor上なので、`nonisolated` を削除して両者を揃える。他のタスクローカル値はactor指定のない `MarkdownHTMLExporter` 内にあり、同じ不整合はない。
- 印刷キャンセル時の非推奨API `NSApp.endSheet` は、シートを持つ `window.endSheet` に置き換える。

## 再発確認

```sh
swift build --configuration release
swift test
python3 -B -m unittest discover -s Tools -p 'test_*.py' -v
```

コンパイルエラーの回帰確認にはリリースビルドが必要。既存の `Tools/ci.sh` も全ユニットテストとリリースビルドを実行する。

`EditorFormattingToolbarTests` は、ツールバーが `CustomizableToolbarContent` として組み立てられ、明示的な項目の順序と内容が `EditorCommand.toolbar` と一致することを確認する。

`LocalImagePreviewTests.testImageRequesterScopesRestoreTheExportDefault` は、main actor上でタスクローカル値を読み書きし、ネストと例外のあとに元の値へ戻ることを確認する。プレビューの要求元が書き出し・印刷へ漏れると同期的な画像読み込みが失われるため、既定の `nil` に戻ることも検証する。画像の背景読み込みと印刷キャンセルは既存の `LocalImagePreviewTests` と `MarkdownPDFExporterTests` で検証する。

## 検証時の記録（2026-10-08）

Apple Swift 6.3.3、macOS SDK 26.5でリリースビルドが成功し、提示されたエラーと印刷APIの非推奨警告が解消した。追加した回帰テスト2件とPythonテスト10件も通過した。

全ユニットテスト886件では、883件通過、2件スキップ、印刷の `testNativePrintCancellationThrowsWithoutCancellingTask` 1件が2つのアサーションで失敗した。同じテストは単独実行では通過した。印刷APIだけを変更前の `NSApp.endSheet` に戻して全体を実行しても同じ失敗が再現したため、今回のAPI置き換えが原因ではない。全体実行時の印刷キャンセルについては、別途実行順序やAppKitの状態を調査する必要がある。
