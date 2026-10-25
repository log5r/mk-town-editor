# テストカバレッジ調査（2026-10-23）

編集・解析・ファイル操作の中核には回帰テストが揃っている。ただし、共同編集の通信とIME、ファイル移動の取消・復旧、画面から編集処理への接続に未検証の経路が残っているため、アプリ全体のテストが十分とは判断できない。以下はテスト不足の調査結果であり、不具合を再現したという報告ではない。

対象コミットは `a2e48a676dcfc9d6e797fc76e65414e7f7d87aaa`。macOS 27.0.1 / Apple Silicon / Swift 6.4で、Swift PackageのDebug構成を計測した。調査開始時の作業ツリーに変更はなかった。

## 実行結果と集計範囲

| 項目 | 結果 |
| --- | --- |
| Swiftユニットテスト | 1,131件中1,126件成功、5件スキップ、失敗0件 |
| Pythonユニットテスト | 56件成功、失敗0件 |
| アプリ本体のSwiftファイル | 144ファイルすべてが計測対象 |
| 行カバレッジ | **57.10%**（26,283 / 46,028） |
| 関数カバレッジ | **60.62%**（3,997 / 6,593） |
| 領域カバレッジ | 63.99%（11,239 / 17,563） |
| 実行された行がないファイル | 28ファイル。主にシート・画面の実装 |

カバレッジは `Sources/MKTownEditor/` のみを集計し、テストコード、依存ライブラリ、生成コードを除外した。数値はLLVMの `summary.lines`、`summary.functions`、`summary.regions` に対応する。行数の分母はLLVMの計測値であり、ファイルの物理的な行数とは一致しない場合がある。`llvm-cov report` の集計値とも照合済みである。

今回のSwiftの計測結果には分岐カバレッジのデータがなく、分岐率は算出していない。後述の「0回」は、関数または特定のコード領域の実行回数を示す。行や関数の実行は、その結果が十分にアサートされていることまでは保証しないため、テスト内容も読み合わせた。

スキップされた5件は `CodeSyntaxPerformanceTests` の性能計測で、`MKTOWN_PERF=1` を指定したRelease実行が必要である。今回は性能、Xcodeのアプリをホストとする構成、UIテスト、2台の端末での共同編集は検証していない。既存のユニットテストに含まれるAppKit/SwiftUIの実ビュー検証は実行した。

初回は実行環境の制限によりSwiftのキャッシュ書込みとPythonテスト内のアセットコンパイルに失敗した。制限を調整した再実行で上記の結果を得た。成功したSwift実行にも `xcsift` が報告する警告が11件あり、actor isolation、SceneStorageのテスト内使用、プレビューの無限幅などが含まれる。

## 主なファイルの行カバレッジ

| ファイル | 行カバレッジ |
| --- | ---: |
| `DocumentAnalysisStore.swift` | 100.00% |
| `MarkdownAnalysis.swift` | 99.24% |
| `GitRepository.swift` | 95.93% |
| `CollaborativeDocument.swift` | 95.30% |
| `MarkdownEditorModel.swift` | 94.14% |
| `MarkdownRenderer.swift` | 93.76% |
| `WorkspaceFileOperations.swift` | 92.40% |
| `Publication.swift` | 79.44% |
| `MarkdownPreview.swift` | 76.27% |
| `MarkdownTextEditor.swift` | 76.15% |
| `AISuggestion.swift` | 56.21% |
| `WorkspaceSnapshotHistory.swift` | 35.28% |
| `ExternalDocumentConverter.swift` | 35.00% |
| `EditorWorkspace.swift` | 33.95% |
| `CollaborationSession.swift` | 12.97% |
| `WorkspaceFileOperationSheet.swift` | 1.28% |

`WorkspaceSnapshotHistory.swift` や `ExternalDocumentConverter.swift` はUIも含む。ファイル全体の低い率を、保存処理や変換処理そのものの率として解釈しないこと。優先度は次の具体的な未検証経路で判断する。

## 優先して追加したいテスト

### 共同編集の接続とIME確定後の適用

[`CollaborationSession.swift`](../Sources/MKTownEditor/CollaborationSession.swift) の `host`、`browse`、`join`、`reconnect`、`localChange`、`receive`、招待認証と接続状態変更のdelegateは実行0回だった。`stop` は他のテストから4回実行されている。既存の [`CollaborativeDocumentTests`](../Tests/MKTownEditorTests/CollaborativeDocumentTests.swift) は文書モデルの収束・配送順序・切断中の独立編集を検証するが、接続や初期同期の制御には到達しない。

さらに、[`EditorWorkspace.swift`](../Sources/MKTownEditor/EditorWorkspace.swift) の `applyCollaborativeText`（2318行）、IME終了通知の受信（1245行）、文書変更から共同編集への通知（1306行）、遠隔更新の受信（1318行）も0回だった。[`CollaborativeTextReplacementTests`](../Tests/MKTownEditorTests/CollaborativeTextReplacementTests.swift) は編集ロックや通知を個別に検証している。

通信を差し替えられる構成で、参加→初期同期→切断→編集→再接続、誤った参加コード、停止済みセッションの通知、不正・過大パケットを検証する。IMEでは、既存の日本語本文を変換中に遠隔更新を受け、確定・取消・表示モード切替の後もローカルの編集と遠隔更新が仕様どおり保持されることを、ワークスペースの実際の通知経路で確認する。[実機確認の記録](production-launcher.md)にも、2台での接続と権限ダイアログが未確認とある。

### ファイル移動完了後の取消・復旧

[`WorkspaceFileOperationSheet.swift`](../Sources/MKTownEditor/WorkspaceFileOperationSheet.swift) の `preparePlan` と `apply` は0回だった。278–284行の「ディスク移動完了→取消確認→書込み結果検証→開いた本文の更新」と、305–328行の巻き戻し・計画破棄・ロック解除が未実行である。

[`WorkspaceFileOperationsTests`](../Tests/MKTownEditorTests/WorkspaceFileOperationsTests.swift) は移動処理内の途中失敗や手動の巻き戻し、[`WorkspaceOpenBufferTests`](../Tests/MKTownEditorTests/WorkspaceOpenBufferTests.swift) は成功時の本文同期を検証する。追加対象は、移動直後に取消または本文検証失敗を起こし、ディスクと開いた本文が復旧し、ロックが解除され、新しい計画で再試行できること。操作の制御部分を抽出して待機位置を注入すれば、重いUIテストを使わずに検証できる。

### スナップショットの保存・統合途中のI/O失敗

[`WorkspaceSnapshotHistory.swift`](../Sources/MKTownEditor/WorkspaceSnapshotHistory.swift) のストアは `save` が44回、`moveHistory` が48回実行された。一方、本文保存後の索引更新失敗に対する後始末（98–101行）、履歴移動失敗の捕捉（192–194行）、統合途中の移動失敗への対応（282–287行）は0回だった。

[`WorkspaceSnapshotHistoryTests`](../Tests/MKTownEditorTests/WorkspaceSnapshotHistoryTests.swift) は通常・並列の統合や旧形式に対応している。索引の書込み失敗や統合途中のファイル移動失敗を注入し、既存履歴と移動済みの履歴を復元できること、再試行で欠落・重複しないことを追加したい。[保存形式と移動の設計](workspace-snapshots.md)も参照する。

### 外部変換中の保存先変更

[`ExternalDocumentConverter.swift`](../Sources/MKTownEditor/ExternalDocumentConverter.swift) の `convert` は6回実行されたが、129–130行の保存先変更を拒否する領域と、134行の新規保存先への移動は0回だった。既存テストの正常終了は、既存ファイルへの上書きである。

待機できる偽コンバーターを使い、変換中に保存先を更新・作成・削除した場合、`destinationChanged` となって外部変更を上書きしないことを検証する。保存先が存在しない場合の正常終了も追加する。現状の失敗・取消時の既存ファイル保護や子プロセス回収は [`ExternalDocumentConverterTests`](../Tests/MKTownEditorTests/ExternalDocumentConverterTests.swift) で検証されている。

### プレビューのチェック操作とUndo

[`MarkdownPreview.swift`](../Sources/MKTownEditor/MarkdownPreview.swift) のチェックボックス変更通知（476行）と、[`EditorWorkspace.swift`](../Sources/MKTownEditor/EditorWorkspace.swift) のコールバック（1575行）、表示モード別に処理を分ける `toggleTask`（2572行）は0回だった。プレビューの構築やモデルの直接編集、[`PreviewTaskUndoTargetTests`](../Tests/MKTownEditorTests/PreviewTaskUndoTargetTests.swift) のUndo用ヘルパーは検証されている。

実ワークスペースの分割表示・プレビュー専用表示でチェック→Undo→Redoを確認する。解析待ちやプレビュー停止後に本文が変わった場合は操作を無効にし、解析更新後は意図した行だけ変更することも検証する。

### AI・公開のHTTP処理と資格情報保存

[`AISuggestion.swift`](../Sources/MKTownEditor/AISuggestion.swift) のtransportの `suggest` とリダイレクト拒否、[`Publication.swift`](../Sources/MKTownEditor/Publication.swift) のtransportの `perform` とリダイレクト拒否、両者のKeychainの `save` / `load` は0回だった。リクエスト生成・応答解析や、通信をクロージャで差し替えた公開処理は検証されている。

テスト用transportやKeychainアダプタで、リダイレクト拒否、401・429・500、タイムアウト・取消、資格情報の保存・更新・未登録・保存拒否を確認する。実アカウントへの送信や実際の認証情報を使う必要はない。

## 既存テストの強み

- 保存形式はUTF-8、不正バイト、BOM、混在改行、Unicodeを含む組合せを検証している。
- IMEは実 `NSHostingView` の再描画を経て確定文字が残ること、キー操作は実 `NSTextView` でUndoを検証している。[IMEの回帰調査](ime-composition-reset.md)と[Undoグループの方針](undo-grouping-in-tests.md)がある。
- プレビュー内数式は8種の文脈で実レイアウトと可視ピクセルを検証し、PDFはページ内容と取消時の後始末まで確認している。
- ファイル操作は同じサイズ・日時の外部変更、途中書込み失敗、複数ウインドウの不一致を検出するテストがある。
- Gitは一時リポジトリでコミット対象の限定、hook失敗、競合解決を検証する。PythonもCIの失敗伝播やリリース処理の各段階の失敗を検証している。

## 継続的な計測と再実行

[`Tools/ci.sh`](../Tools/ci.sh) はPython全テスト→Swift全テスト→Releaseビルドを実行するが、カバレッジは有効にしていない。[CIワークフロー](../.github/workflows/ci.yml)も保存するのはログであり、カバレッジの履歴や低下の検出はない。

次の改善では、上記の状態遷移・失敗経路のテストを優先し、CIでもアプリ本体だけのカバレッジを保存して比較できるようにする。全体率の目標を先に置くより、データを変更する処理の未実行経路を減らし、変更したコードのテストをレビューする方が今回の不足に対応できる。

リポジトリ直下で、[AGENTS.md](../AGENTS.md) のログ方針に従って実行する。

```bash
set -o pipefail
command -v xcsift >/dev/null 2>&1 || { echo 'xcsift is unavailable' >&2; exit 127; }
mkdir -p .build-logs || exit 1
COVERAGE_LOG=".build-logs/test-coverage-$(date +%Y%m%d-%H%M%S)-$$.log"
if swift test --enable-code-coverage --force-resolved-versions 2>&1 \
  | tee "$COVERAGE_LOG" | xcsift -f toon -w; then
  COVERAGE_STATUS=0
else
  COVERAGE_STATUS=$?
fi
echo "Exit code: $COVERAGE_STATUS"
echo "Full build log: $COVERAGE_LOG"
exit "$COVERAGE_STATUS"
```

この環境では、成功後のプロファイルとテスト実行ファイルから次のコマンドで集計できる。Swiftの版やビルド方式が異なる場合は、生成先に合わせてパスを変更する。

```bash
xcrun llvm-cov report \
  .build/out/Products/Debug/MKTownEditorTests.xctest/Contents/MacOS/MKTownEditorTests \
  -instr-profile=.build/out/Products/Debug/codecov/default.profdata \
  -ignore-filename-regex='/(Tests|\.build)/'
```

今回のローカル成果物は以下に保存した。`.build/` と `.build-logs/` はGit管理の対象外である。`summary.json` はアプリ本体だけの集計で、HTMLには行ごとの実行結果が含まれる。

- 成功したSwiftテスト：`.build-logs/test-coverage-20261023-032628-66040.log`
- 成功したPythonテスト：`.build-logs/test-python-20261023-032712-67772.log`
- ファイル別集計：`.build-logs/coverage-20261023-032628/report.txt`
- 集計JSON：`.build-logs/coverage-20261023-032628/summary.json`
- HTMLレポート：`.build-logs/coverage-20261023-032628/html/index.html`
- 元の詳細JSON：`.build/out/Products/Debug/codecov/MKTownEditor.json`
