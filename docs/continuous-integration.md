# GitHub ActionsによるCI

## 実行構成

`.github/workflows/ci.yml`はpush、Pull Request、手動実行を受け付ける。`xcode-27` runner（macOS 27）でXcode 27.0を`DEVELOPER_DIR`に指定し、`bash Tools/ci.sh`を実行する。Xcodeプロジェクトにはテストターゲットがないため、既存のSwift Packageのテストターゲットを使う。

`Tools/ci.sh`はリポジトリのルートへ移動し、Pythonのスクリプトテスト、Swiftの全ユニットテスト、Swift PackageのReleaseビルドを順番に実行する。AppKitやWebKitを扱うテストがあるため、Linux runnerやテストの並列実行は使わない。署名や配布は行わない。

`--force-resolved-versions`を使い、`Package.resolved`の依存バージョンを維持する。ロックファイルとパッケージ定義が合わない場合はCIを失敗させる。ビルドキャッシュは導入せず、まず毎回のビルドとテストを確認する。

## ツールチェーンの選択

既存コードはXcode 16.4と26.6でコンパイルエラーになった。16.4では型検査、MainActorの呼び出し、Mermaidの継続への結果送信でエラーが出た。26.6でもMarkdownメニューのSwiftUIビルダーで`extra argument in call`、ワークスペースビューで型検査の時間超過が出た。ローカルのXcode 27では全811テストとReleaseビルドが成功したため、CIもXcode 27.0に固定する。

`xcode-27` runnerはGitHubで公開プレビュー扱いである。アプリのビルド環境に合わせて採用し、プレビューのrunnerであることをREADMEにも記載する。テストの省略やコンパイルエラーの無視は行わない。

## 失敗時の挙動

スクリプトは`set -euo pipefail`で最初の失敗を返す。Actionsの`run`にも`bash`を明示することで、ログ保存の`tee`が成功してもテストやビルドの失敗を失わない。テストが失敗した場合はReleaseビルドを実行しない。

Actionsの一時フォルダに実行ログを保存し、成功・失敗の両方で`ci-results`として7日間保持する。ローカル実行ではターミナルへ出力する。

Swift 6.1の`--xunit-output`は、逐次実行のXCTest結果をXMLに出力しない。Swift Testingだけの空のレポートを全テストの結果として扱わないため、今回は全件の結果を含む実行ログを保存する。XML生成のための`--parallel --num-workers 1`はテストごとにプロセスを起動するため、既存の一括実行を維持する。

同じrefへの新しい実行は古い実行をキャンセルする。ジョブの上限は30分。`GITHUB_TOKEN`の権限は`contents: read`のみとし、checkout後の認証情報は保持しない。利用する公式ActionsはコミットSHAで固定する。

## 検証方法

- `python3 -B -m unittest discover -s Tools -p 'test_*.py' -v`で、起動スクリプトとCIスクリプトを検証する。CIスクリプトのテストでは外部コマンドを模擬し、失敗時の停止・終了コード・空白を含むパス・ログ用パイプラインを確認する。
- `bash Tools/ci.sh`で、実際の全ユニットテストとReleaseビルドを実行する。
- `actionlint .github/workflows/ci.yml`で、Actionsの構文と式を検証する。
- GitHub上ではActionsの`CI`を開き、`Build and unit tests`と`ci-results`を確認する。

## 参照

- [GitHub Actions workflow構文](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
- [Xcode 27 runnerのツール一覧](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md)
- [actions/checkout](https://github.com/actions/checkout)
- [actions/upload-artifact](https://github.com/actions/upload-artifact)
- [Swift 6.1のテスト実行とXML生成](https://github.com/swiftlang/swift-package-manager/blob/swift-6.1.2-RELEASE/Sources/Commands/SwiftTestCommand.swift)

- [Xcode 27 runnerの公開プレビュー告知](https://github.com/actions/runner-images/issues/14404)
