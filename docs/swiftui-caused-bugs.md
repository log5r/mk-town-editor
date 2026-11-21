# 不具合の原因に占めるSwiftUIの仕様（2026-11-21調査）

これまでに修正した不具合のうち、SwiftUIの仕様が原因だったものを数えた。原因の記録が残っている不具合は約25件で、次のように分かれる。

| 分類 | 件数 |
|---|---|
| SwiftUIの仕様が直接の原因 | 7件 |
| SwiftUIとAppKit・UIKitの接続部で起きたもの | 4件 |
| SwiftUIが原因ではないもの | 約14件 |

## 調査の方法と限界

- `docs` の各文書の原因の節と、コミット履歴（マージを除く397件）のメッセージから分類した。
- 母数の約25件は概算である。件名に「修正」「Fix」などを含むコミットは23件あるが、1つのコミットが複数の不具合を直している場合と、文書だけに記録がある場合がある。
- レビュー指摘をまとめて直したコミット（`70b03d9`、`85a803e`、`ffc0bdd` など）の個々の修正は分類していない。
- 分類は記録された原因に基づく。今回、不具合を再現して確かめ直してはいない。

## SwiftUIの仕様が直接の原因（7件）

うち4件は、SwiftUIの `Text` が属性付き文字列の一部の属性を無視することが原因である。

| 不具合 | 原因になった仕様 | 記録 |
|---|---|---|
| 入れ子のリストが平坦になる | `Text` が段落スタイルの字下げ（`firstLineHeadIndent`・`headIndent`）を無視する | [preview-list-nesting.md](preview-list-nesting.md) |
| リストの行間が設定どおりにならない | `Text` が段落スタイルの `lineSpacing`・`paragraphSpacing` を無視する | [preview-block-spacing-and-borders.md](preview-block-spacing-and-borders.md) |
| インライン数式がプレビューから消える | `Text` が `NSTextAttachment` を表示しない | [inline-math-preview.md](inline-math-preview.md) |
| テーマのリンク色が反映されない | `Text` がリンクを tint で描き、文字色の属性を無視する。`NSTextView` も `linkTextAttributes` で描くため同じ結果になる | [preview-themes.md](preview-themes.md) |
| iOSで入力のたびに本文が揺れる | `TextEditor` がバインディング更新のたびに本文全体をレイアウトし直す | [mobile-editor-scroll-jump.md](mobile-editor-scroll-jump.md) |
| 起動のたびに名称未設定ウインドウが増える | `DocumentGroup` が、ウインドウを復元した起動でも新規書類を必ず1つ開く。AppKitの状態復元が空のウインドウを戻すことと重なって発生した | [untitled-window-accumulation.md](untitled-window-accumulation.md) |
| リリースビルドのエラー | 長い修飾子チェーンでの型チェックの時間超過、`CommandsBuilder` の要素数10個の上限、`ForEach` がカスタマイズ可能なツールバー項目に適合しない | [swiftui-build-errors.md](swiftui-build-errors.md) |

リリースビルドのエラーは実行時の不具合ではなく、コンパイル時の問題である。同じ文書にある `@TaskLocal` のactor分離エラーと非推奨APIの置き換えは、SwiftUIの仕様によるものではない。

## SwiftUIとAppKit・UIKitの接続部で起きたもの（4件）

SwiftUIの再描画の仕組みがきっかけだが、修正したのはアプリ側の接続コードである。

| 不具合 | 原因 | 記録 |
|---|---|---|
| 日本語入力の変換中に文字が消える | 再描画のたびに `updateNSView` がバインディングの本文でテキストビューを置き換え、変換中の文字列を破棄していた | [ime-composition-reset.md](ime-composition-reset.md) |
| 検索の候補数が消える | 再描画のたびに、編集可否・スペルチェック・自動修正の設定を同じ値のままAppKitへ再代入していた | [find-and-replace.md](find-and-replace.md) |
| DuoのClosed状態で件数欄が本文に重なる | 標準検索UIが内部のテキストビューの領域を変えるため、`TextEditor` への下部セーフエリア挿入だけでは本文と件数欄を分離できなかった | [find-and-replace.md](find-and-replace.md) |
| ビュー更新中の状態通知の警告 | 選択範囲などの状態を、ビューの更新中に通知していた | コミット `c397a98` |

最後の1件は、対応する文書が `docs` に見当たらない。コミットメッセージだけで分類した。

## SwiftUIが原因ではないもの（約14件）

| 不具合 | 原因の所在 | 記録 |
|---|---|---|
| KaTeX・MathJax向けの数式が原文表示になる | 数式の解析 | [math-katex-compatibility.md](math-katex-compatibility.md) |
| コードブロック内の語にスペルミスの下線が付く | 校正の対象範囲 | [proofing-protected-ranges.md](proofing-protected-ranges.md) |
| HTML書き出しでローカル画像を参照できない | 書き出しの参照方法 | [html-export-image-sources.md](html-export-image-sources.md) |
| 行番号のY座標が揺れる | TextKitの行の矩形の扱い | [line-number-vertical-alignment.md](line-number-vertical-alignment.md) |
| `swift run` で起動すると文字を入力できない | Info.plistのない実行ファイルに対するAppKitのactivation policy | [package-launch-activation.md](package-launch-activation.md) |
| ワークスペースのルートが読めないとサイドバーが空になる | ワークスペースの読み込み | [workspace-root-unavailable.md](workspace-root-unavailable.md) |
| 改名・移動でスナップショットの履歴が見えなくなる | スナップショットの保存先 | [workspace-snapshots.md](workspace-snapshots.md) |
| 字句の受け渡しの不具合 | Tree-sitterとの連携 | [tree-sitter-integration.md](tree-sitter-integration.md) |
| Xcodeホストで連続コマンドのUndoテストが失敗する | Undoグループの区切り | [undo-grouping-in-tests.md](undo-grouping-in-tests.md) |
| CIの設定検査の失敗 | ワークフロー定義とXcodeプロジェクトの書式 | [ci-configuration-failures.md](ci-configuration-failures.md) |
| ダークなどの外観でアイコンの文字が読めない、Icon Composerがない環境でテストが失敗する | アイコンの書類とテスト環境 | [app-icon.md](app-icon.md) |
| iOSの文字列カタログが誤ってstaleになる | 文字列カタログの検査 | [localization.md](localization.md) |
| 表の罫線が薄い、コールアウトの縦線が破線になる | アプリ側の描画の実装 | [preview-block-spacing-and-borders.md](preview-block-spacing-and-borders.md) |

## 分類から分かること

- **`Text` に属性付き文字列を渡す経路は要注意である。** 字下げ、行間、添付画像、リンクの文字色がいずれも無視された。4件とも、属性付き文字列の中身を調べるテストは通っていた。表示の経路を変えるときは、描画結果の属性だけでなく、実際の表示経路がその属性を使うかを検証する。
- **`updateNSView`・`updateUIView` は、本文が変わっていなくても頻繁に呼ばれる。** 値が変わっていないときは代入しない。IMEの変換中のように、テキストビューとバインディングの内容が一致しない期間があることも前提にする。
- **標準部品の内部動作に起因する問題は、修飾子の調整では直らなかった。** `TextEditor` の揺れは `UITextView` を包むビューへの置き換え、`Text` の字下げは `NSTextView` での描画で解決した。原因の切り分けでは、修飾子のない最小の構成でも再現するかを先に確かめる。

## その後の対応（2026-11-22）

構造化プレビューの文字列をすべて `NSTextView`（`HoverLinkText`）で描くように切り替え、`Text` に属性付き文字列を渡す経路をなくした。経緯と性能は [preview-text-backend-performance.md](preview-text-backend-performance.md) にある。
