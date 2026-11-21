# CIの設定検査と検証方法

CIの`Script tests`ジョブ（`bash Tools/ci.sh python`）は、アプリをビルドせずに設定ファイルの整合性を検査する。この検査で失敗したときの読み方と、手元での確かめ方をまとめる。

2026-10-10のコミット`82c10e1`で直した2件の失敗が、この検査のもとになっている。当時の実行ログは残っていないため、原因の説明はそのコミットの差分と追加したテストに基づく。

## 検査の対象

| 対象 | テスト | 読み取り方 |
|---|---|---|
| `.github/workflows/ci.yml`・`release.yml` | [`Tools/test_ci.py`](../Tools/test_ci.py)の`WorkflowConfigurationTests` | `/usr/bin/ruby`の標準YAMLパーサ |
| `MKTownEditor.xcodeproj/project.pbxproj`と共有スキーム | [`Tools/test_xcode_project.py`](../Tools/test_xcode_project.py) | `/usr/bin/plutil`でXMLに変換して`plistlib`で読む |
| `README.md`と`docs`内の相対リンク | [`Tools/test_docs_links.py`](../Tools/test_docs_links.py) | Markdownのリンク記法を抽出 |

`ruby`と`plutil`はmacOSに標準で入っている。CIに追加のPythonモジュールを入れずに済むよう、この2つを使っている。

## ワークフロー定義が原因の失敗

### `runner`コンテキストをジョブの`env`で使った

`release.yml`はジョブの`env`に`RELEASE_OUTPUT_DIR: ${{ runner.temp }}/release-output`を書いていた。`runner`コンテキストはステップの中でしか使えず、ワークフロー直下とジョブ直下の`env`では使えない（[GitHubのコンテキストの説明](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability)）。この場合、ワークフローの定義自体が無効になり、ジョブが1つも始まらずに実行が失敗する。ステップのログは残らないので、Actionsの実行ページ上部に出るエラーを見る。

修正では、この変数を必要とする各ステップの`env`へ移した。

再発を防ぐテストは次の2つである。

- `test_runner_context_is_not_used_in_workflow_or_job_environment`：2つのワークフローで、ワークフロー直下とジョブ直下の`env`に`runner.`を含む式がないことを確かめる。
- `test_release_build_publish_and_diagnostics_share_the_output_directory`：ビルド、公開、公証ログのアップロードが同じ出力ディレクトリを指すことを確かめる。変数をステップごとに書くようになったので、値がずれると成果物を見つけられなくなる。

`runner.temp`などが必要なときは、ステップの`env`に書くか、シェルの中で`$RUNNER_TEMP`を使う。

### そのほかのワークフロー検査

`WorkflowConfigurationTests`は、ジョブの並列構成、SwiftPMキャッシュの共有、ログのアーティファクト名、iOSのコンパイルに使うスキームも検査する。意図は[CIの実行時間と短縮策](ci-performance.md)にある。ジョブやステップの名前を変えるときは、テストが名前で探している箇所も合わせて直す。

### actionlintを使う場合

[`.github/actionlint.yaml`](../.github/actionlint.yaml)は、プレビュー扱いの`xcode-27` runnerをactionlintに認識させるための設定である。actionlintはCIでは実行していない。手元に入れている場合は、リポジトリのルートで`actionlint`を実行すると式や構文の誤りをpush前に調べられる。

## Xcodeプロジェクトの書式変更が原因の失敗

`test_xcode_project.py`は以前、`project.pbxproj`の文字列を正規表現で読んでいた。この方法は、Xcodeが書き出す空白や改行、`/* 名前 */`形式のコメントに依存する。Xcodeがファイルを書き直して書式が変わると、プロジェクトの内容が正しくてもテストが失敗する。

修正では、`plutil`でプロジェクトをプロパティリストとして読み、オブジェクトのIDと値で検査するようにした。書式の違いに左右されないことは`ProjectParsingTests`が確かめている。対象にしている違いは次のとおり。

- 配列の開き括弧の直後が空白か改行か
- コメントに`/`や空白が含まれるか
- 全体を1行に詰めても同じ結果になるか

壊れたプロジェクトファイルは、`plutil`の失敗として検出する（`test_invalid_project_is_rejected`）。

プロジェクトの検査を追加するときは、`self.objects`から値をたどる。`self.project`の文字列に対して正規表現を書かない。

### 書式ではなく内容が原因の場合

同じテストファイルは、プロジェクトの内容も検査している。よくある失敗は、`Sources/MKTownEditor`か`Sources/MKTownMarkdownCore`にSwiftファイルを追加して、Xcodeのアプリターゲットへ追加し忘れた場合である（`test_app_target_compiles_every_package_source_file`）。ターゲットの構成は[Xcodeプロジェクトの構成](xcode-project-structure.md)を参照する。

## ドキュメントのリンク切れ

`test_docs_links.py`は、`README.md`などリポジトリ直下のMarkdownと`docs`内のMarkdownから相対リンクを抜き出し、リンク先が存在すること、Gitの無視対象でないことを確かめる。コードブロックとインラインコードの中、外部URL、ページ内リンクは対象にしない。`#見出し`の部分は検査しない。

READMEがこの文書にリンクしていながら、文書がコミットされていなかったことから追加した。`docs-local`は無視対象なので、公開ドキュメントからリンクすると失敗する。

## 手元での検証

設定検査をまとめて実行する。

```sh
bash Tools/ci.sh python
```

1つのファイルだけ実行する場合は、ファイルを直接指定する。

```sh
python3 Tools/test_ci.py
python3 Tools/test_xcode_project.py
python3 Tools/test_docs_links.py
```

プロジェクトファイルが読めるかどうかだけを確かめる場合は、次のコマンドを使う。

```sh
plutil -lint MKTownEditor.xcodeproj/project.pbxproj
```

CIで失敗した場合は、Actionsの`ci-results-script-tests`アーティファクトにある`script-tests.log`で、失敗したテスト名を確認する。
