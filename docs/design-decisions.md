# 設計判断

## 方針

CodiMD の特徴のうち、Markdown ソースとレンダリング結果を同時に確認できる編集体験を採用した。サーバー、アカウント、リアルタイム共同編集は本アプリのローカル書類モデルとは責務が異なるため、初期版には含めない。

## macOS 標準コンポーネント

- `DocumentGroup` と `FileDocument` で「新規」「開く」「保存」「別名で保存」と自動保存をシステムに委ねる。
- `NSTextView` と `NSScrollView` で、Undo、検索バー、スペルチェック、キーボード操作、アクセシビリティを提供する。
- `HSplitView` で編集領域とプレビュー領域の幅をユーザーが調整できるようにする。
- `ToolbarItem` とセグメント形式の `Picker` で表示モードを切り替える。
- SF Symbols とセマンティックカラーを使用し、ライト／ダークモードに追従する。

## Markdown 処理

プレビューは Markdown をブロック単位に分類し、Foundation の `AttributedString` Markdown パーサーでインライン要素を処理して `NSAttributedString` に変換する。見出し、引用、リスト、コードブロックには AppKit の標準フォント、色、段落スタイルを付ける。Web コンテンツや独自 HTML を埋め込まないため、表示がシステムの文字設定とアクセシビリティに自然に追従する。

書式入力は純粋関数 `MarkdownFormatter` として分離し、UTF-16 ベースの `NSRange` を扱う。これにより `NSTextView` の選択範囲と日本語入力を安全に接続し、UI を起動せず単体テストできる。
