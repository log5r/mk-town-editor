# インライン数式がプレビューから消える不具合

## 症状と原因

`本文中に $E = mc^2$ のように書けます。` の数式部分だけがプレビューから消えた。
数式の解析と画像生成は成功していたが、リンクを含まない本文を
`Text(AttributedString(rendered))` に渡す経路で `NSTextAttachment` が表示されなかった。
リンク付きの本文は `NSTextView` を使っていたため、同じ数式でも表示できた。

従来のテストはレンダラーの戻り値に添付画像があることと、HTMLに画像が埋め込まれることを
確認しており、実際のプレビューがその画像を保持して表示できるかは検証していなかった。

## 修正

`MarkdownPreview.inlineText` に表示経路の選択を集約する。リンクまたは添付画像がある場合は
既存の選択可能なAppKitテキストビューを使い、それ以外はSwiftUIの `Text` を使う。
本文、見出し、タスク、表セルに加え、同じ変換を行っていた注記と脚注にも適用する。
この判定は数式に限定せず、他の添付画像にも適用する。

## 回帰確認

`MarkdownMathTests.testInlineMathSurvivesActualPreviewLayoutInEveryTextContainer` は
`NSHostingView` に実際の `MarkdownPreview` を配置し、本文・見出し・タスク・表・引用・注記・
脚注・リンク付き本文の8パターンを検証する。添付画像の保持、画像の可視ピクセル、
レイアウト上の数式の幅・高さ、テキストビューの高さを確認する。
修正前はリンク付き本文以外の7パターンで失敗する。

```sh
swift test --filter MarkdownMathTests
swift test
python3 -B -m unittest discover -s Tools -p 'test_*.py' -v
swift build --configuration release
```

手動確認では、拡張Markdownの分割表示で上記の日本語本文を入力し、右側に式が表示されることを確認する。
基本Markdown、コード内、未完成の数式は従来どおり原文表示とする。

## 2026-10-08の検証結果

追加した回帰テストを含む数式・リンクホバー・レンダラーの44テスト、およびPythonの10テストが通過した。
全Swiftテスト887件は884件通過、2件スキップ、印刷キャンセルの1件が2アサーションで失敗した。
失敗は[既存の調査記録](swiftui-build-errors.md#検証時の記録2026-10-08)と同じ
`MarkdownPDFExporterTests.testNativePrintCancellationThrowsWithoutCancellingTask` だった。
この印刷テストは単独実行では通過した。リリースビルドも成功した。
