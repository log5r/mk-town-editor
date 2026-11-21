# CIの実行時間と短縮策

2026-11-21に[CIワークフロー](../.github/workflows/ci.yml)の実行時間を調べ、ジョブの並列化と依存ライブラリのキャッシュを入れた。調べ方と判断の理由を残す。

## 変更前の内訳

変更前は1つのジョブですべてを直列に実行しており、成功した実行は8.7〜14.9分かかっていた。`main`の実行44888904668（592秒）の内訳は次のとおり。

| フェーズ | 時間 |
|---|---|
| SwiftPM依存の取得 | 約164秒 |
| Releaseビルド（`swift build -c release`） | 約119秒 |
| Debugビルド（`swift test`の前段） | 約98秒 |
| Swiftテスト（1177件） | 約85秒 |
| Pythonテスト（94件） | 約59秒 |
| iOSの`build-for-testing` | 約53秒 |

依存の取得が最も長い。tree-sitter本体（約7.7万オブジェクト）と各言語の文法リポジトリを、実行のたびに全履歴ごとクローンしていた。

## 入れた対策

- **ジョブの並列化**: Pythonテスト、Swiftテスト、Releaseビルド、iOSのコンパイルを別々のジョブにした。互いに`needs`を持たせないので、待ち時間は最も長いジョブで決まる。[`Tools/ci.sh`](../Tools/ci.sh)は`python`・`test`・`release`の引数で1段階だけ実行でき、引数なしでは従来どおり全段階を順に実行する。
- **SwiftPM依存のキャッシュ**: `~/Library/Caches/org.swift.swiftpm`を`actions/cache`で保存する。`swift`コマンドと`xcodebuild`はどちらもこのディレクトリのリポジトリを使うので、3つのジョブで同じキーを共有できる。キーは2つの`Package.resolved`のハッシュで、依存を更新したときだけ取得し直す。

`.build`のビルド成果物はキャッシュしていない。チェックアウトのたびにソースの更新時刻が変わり、再利用できる範囲が安定しないためである。

## 注意点

- Pull Requestで作られたキャッシュはそのブランチでしか使えない。`Package.resolved`を変更した直後は、`main`での実行が終わるまで各Pull Requestが一度ずつ取得し直す。
- ジョブを分けたので、ログのアーティファクトは`ci-results-<ジョブ名>`に分かれる。
- ジョブを分けるとランナーの合計利用時間は増える。このリポジトリは公開リポジトリなので課金には影響しない。
- `main`のルールセットは必須ステータスチェックを指定していない。指定する場合は新しいジョブ名（Script tests、Unit tests、Release build、iOS build）を使う。

## 見送った案

- **`swift test --parallel`**: ウィンドウやワークスペースの状態を扱うテストが多く、不安定になるおそれがある。
- **遅いテストの見直し**: `MarkdownRulerWorkspaceTests.testWorkspaceRulerPositionsWhileAppendingAndRemovingBlankLines`（約15秒）と`EditorWorkspacePersistenceTests`（9件で約14秒）が突出している。未着手。

## 実行時間の調べ方

実行ごとの所要時間は次のコマンドで一覧できる。

```sh
gh run list --limit 20 --json databaseId,conclusion,startedAt,updatedAt
```

ステップ別の時間は`gh run view <実行ID> --json jobs`で得られる。ステップ内の内訳は`gh run view <実行ID> --log`のタイムスタンプから、`Fetching`・`Building for`・`Build complete`・`Test Suite 'All tests'`の各行の時刻差で求める。
