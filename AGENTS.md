# 開発方針

- Human Interface Guideline (https://developer.apple.com/design/human-interface-guidelines) を守って開発する。
- 機能を実装したら対応するテストを必ず書く。
- 実装が完了したら、実装コードをレビューする。
- 作業完了前にユニットテストをすべて実行する。UIテストは負荷が高いため、必要な場合に限り実行する。
- 不具合調査時はナレッジベースを適宜参照する。
- 不具合を修正した時は、その不具合が再現しないことを確認するテストを必ず書く。
- 不具合を修正した後は、同じ原因が別の呼び出し元・状態遷移・処理経路にないか検索して確認する。
- 再利用できる調査結果、設計判断、不具合の原因と検証方法はナレッジベースとして蓄積する。(docsフォルダを作ってmdファイルまたはHTMLで保存することを推奨する)

# AIエージェントのビルド・テストログ

- AIエージェントが `xcodebuild`、`swift build`、`swift test` を実行する場合は、標準出力と標準エラーを `2>&1` でまとめ、`tee` で全ログを保存してから `xcsift -f toon -w` に渡す。エージェントに返す出力は整形結果、終了コード、全ログの保存先に限定する。
- 全ログはリポジトリ直下の `.build-logs/` に保存する。実行ごとに日時とプロセスIDなどを付けたファイル名を使い、以前のログを上書きしない。ログはGitにコミットしない。
- `set -o pipefail` を有効にし、ビルド・テストやログ処理の失敗を成功として扱わない。パイプライン直後に終了コードを保存し、保存先を表示した後もその終了コードで終了する。`set -e` が有効でも保存先を表示できるよう、パイプラインを `if` で実行する。
- 詳細調査が必要な場合は、まず保存済みログを `xcsift` で再解析する。追加情報が必要な場合も `rg` や行範囲の指定で必要箇所だけを読む。全ログを `cat` したり、未整形の全出力をエージェントに返したりしない。
- 実行前に `command -v xcsift` で利用可能か確認する。未導入などで利用できない場合はその理由を報告し、全ログをファイルに保存したうえで、終了コード、保存先、必要最小限の診断だけを返す。
- ビルドを伴うスクリプトやツールを使う場合も、このログ方針を適用する。

リポジトリのルートで実行する例（Bash）：

```bash
set -o pipefail

command -v xcsift >/dev/null 2>&1 || { echo "xcsift is unavailable" >&2; exit 127; }
mkdir -p .build-logs || exit 1
LOG=".build-logs/build-$(date +%Y%m%d-%H%M%S)-$$.log"

if xcodebuild -project MKTownEditor.xcodeproj -scheme MKTownEditor build 2>&1 \
  | tee "$LOG" \
  | xcsift -f toon -w; then
  BUILD_STATUS=0
else
  BUILD_STATUS=$?
fi

echo "Exit code: $BUILD_STATUS"
echo "Full build log: $LOG"
exit "$BUILD_STATUS"
```

テストでは `xcodebuild ... test` または `swift test` に置き換え、ログ名も `test-...` にする。オプションは [xcsiftの公式ドキュメント](https://github.com/ldomaradzki/xcsift) を参照する。

# ドキュメント方針

- READMEにはプロジェクトの概要、起動方法、基本操作、開発・テスト手順をまとめる。
- READMEが長くなる場合は、詳細をGitで追跡するdocsフォルダへ分け、READMEから相対リンクを張ってよい。
- 公開ドキュメントはリポジトリ内のdocsフォルダで管理する。docs-localフォルダは比較・参照用のローカル資料として扱う。
