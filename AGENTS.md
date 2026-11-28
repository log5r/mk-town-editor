# MKTownEditor 開発ガイド

## 実装・テスト

- 開発では Apple の [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines) に従う。
- 機能を実装したら、その動作を検証するテストを追加する。不具合を修正したら、再発を検出する回帰テストを追加する。
- 実装後は変更したコードをレビューする。
- 作業完了前にすべてのユニットテストを実行する。実行手順は [Swift Package と開発スクリプトのテスト](README.md#テスト) および [iOS 専用のユニットテスト](docs/iphone-duo-support.md#検証) を参照する。UI テストは必要な場合に限り実行する。

## 不具合調査と記録

- 不具合を調査するときは、[ナレッジベース](docs/) から関連する記録を参照する。
- 修正後は、同じ原因が残っていないか、別の呼び出し元・状態遷移・処理経路を検索して確認する。
- 再利用できる調査結果、設計判断、不具合の原因と検証方法をナレッジベースに記録する。保存先には `docs/` 内の Markdown または HTML ファイルを推奨する。

## AIエージェントのビルド・テストログ

以下の手順は `xcodebuild`、`swift build`、`swift test` の実行と、ビルドを伴うスクリプトやツールの利用に適用する。

1. `set -o pipefail` を有効にする。リポジトリ直下の `.build-logs/` に、日時やプロセス ID などを含む新しいログファイルを作る。ログは Git にコミットしない。
2. 実行前に `command -v xcsift` で利用可否を確認する。利用できる場合は、標準出力と標準エラーを `2>&1` でまとめ、`tee` で全ログを保存しながら `xcsift -f toon -w` に渡す。エージェントに返す出力は整形結果、終了コード、ログの保存先に限る。
3. `xcsift` が利用できない場合は、その理由を報告し、標準出力と標準エラーをログに直接保存する。エージェントに返すのは終了コード、ログの保存先、必要最小限の診断とする。
4. `set -e` が有効でも失敗時に保存先を表示できるよう、パイプラインを `if` で実行し、直後に終了コードを保持する。ビルド・テストやログ処理が失敗した場合も、保存先を表示した後、その終了コードで終了する。
5. 詳細調査では、まず `xcsift -f toon -w < "$log"` で保存済みログを再解析する。情報が足りない場合や `xcsift` が利用できない場合は、`rg` や行範囲の指定で必要箇所だけを読む。未整形の全ログはエージェントの出力に含めない。

リポジトリ直下で Swift Package の全テストを実行する Bash の例。

```bash
set -o pipefail

mkdir -p .build-logs || exit 1
log=$(mktemp ".build-logs/test-$(date +%Y%m%d-%H%M%S)-$$.XXXXXX") || exit 1
test_command=(swift test --force-resolved-versions)

if command -v xcsift >/dev/null 2>&1; then
  if "${test_command[@]}" 2>&1 | tee "$log" | xcsift -f toon -w; then
    run_status=0
  else
    run_status=$?
  fi
else
  printf '%s\n' 'xcsift が PATH に見つからないため、全ログをファイルに保存します。' >&2
  if "${test_command[@]}" >"$log" 2>&1; then
    run_status=0
  else
    run_status=$?
  fi
fi

printf 'Exit code: %s\nFull log: %s\n' "$run_status" "$log"
exit "$run_status"
```

別のテストやビルドでは配列内のコマンドを差し替える。ビルドのログには `build-` で始まる名前を使う。整形オプションは [xcsift の公式ドキュメント](https://github.com/ldomaradzki/xcsift) を参照する。

## ドキュメント

- `README.md` にプロジェクトの概要、起動方法、基本操作、開発・テスト手順をまとめる。長くなる場合は、詳細を `docs/` に分け、README から相対リンクで参照してよい。
- 公開ドキュメントは `docs/` で Git 管理する。`docs-local/` は比較・参照用のローカル資料に使う。
