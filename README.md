# MKTownEditor

macOS向けの、ローカルファイルを扱うMarkdownエディタです。原文とプレビューを並べて確認しながら、メモや記事を編集できます。macOS標準の書類操作、検索、Undo / Redo、スペルチェックに対応し、日本語・英語のUIとVoiceOver向けのラベルを備えています。

通常の編集とプレビューは、アカウントやAPIキーなしでオフラインでも使えます。

[主な機能](#主な機能) · [起動方法](#実行) · [基本操作](#基本操作) · [テスト](#テスト) · [数式の書き方](docs/features.md#数式の書き方)

## 主な機能

| 目的 | できること |
| --- | --- |
| 書く | 書式の挿入・補完、表のグリッド編集、集中モード、タイプライターモード |
| 確認する | 編集・分割・プレビュー表示、スクロール同期、数式・図・脚注の表示 |
| 移動・検索する | アウトライン、ブックマーク、正規表現検索、フォルダ全体の検索・置換 |
| ノートを管理する | ファイルサイドバー、タグ、Wikiリンク、バックリンク、日付ノート、タスク一覧 |
| 文章を整える | 用語辞書、Markdown診断・整形、文字数目標、読了時間の目安 |
| 取り込み・書き出す | HTML・RTFの取り込み、HTML・PDF・テキスト出力、印刷、添付を含むZIP出力 |
| 連携する | Gitの差分・履歴・コミット、iCloudの競合確認、共同編集、公開、AI推敲・翻訳 |

細かな操作、対応構文、機能ごとの制約は[機能ガイド](docs/features.md)にまとめています。コードブロックの色分けに使うTree-sitterの依存と更新手順は[Tree-sitterの導入](docs/tree-sitter-integration.md)にあります。

## 動作環境

- **アプリの実行**：macOS 14以降
- **ビルド・開発**：Xcode 27 / Swift 6.4（CIで検証している環境）
- **CIと同じチェックを実行する場合**：Python 3（設定検査にはmacOS標準の`plutil`と`/usr/bin/ruby`も使用）

Swift Packageの定義はSwift tools 6.0です。初回ビルドでは、依存ライブラリの取得にネットワーク接続が必要です。

## 実行

リポジトリのルートディレクトリで、次のコマンドを実行します。Releaseビルドからアプリバンドル`.build/MKTownEditor.app`を組み立てて起動します。

```sh
./start.sh
```

通常は差分ビルドを行います。ビルド成果物を削除してから起動する場合は`rebuild`を付けます。Debugの成果物も削除されます。書類のパスを続けると、起動後にその書類を開きます。

```sh
./start.sh rebuild
./start.sh notes/example.md
```

アプリバンドルとして起動するので、URLスキーム、Markdownの書類タイプ、サービスメニュー、共同編集のローカルネットワーク利用など、Info.plistに依存する機能も使えます。バンドルの構成と制約（アドホック署名、起動中のアプリとの関係など）は[`start.sh` のアプリバンドル起動](docs/production-launcher.md)にまとめています。

Xcodeを使う場合は、`MKTownEditor.xcodeproj`を開き、`MKTownEditor`スキームを選んで実行します。

`swift run MKTownEditor`でも起動できますが、実行ファイルを直接起動するため、Info.plistに依存する機能は使えません（[`swift run` で起動したときに文字が入力できない問題](docs/package-launch-activation.md)）。SwiftUIのコンパイルエラーについては[原因と検証方法](docs/swiftui-build-errors.md)を参照してください。

## 基本操作

1. 「ファイル」メニューから書類を新規作成するか、既存のMarkdownファイルを開きます。
2. ツールバーで「編集」「分割」「プレビュー」を切り替え、本文を編集します。
3. 「Markdown」メニューから書式、リンク、画像、表などを挿入します。
4. 複数のノートを扱う場合は、「ワークスペース」→「フォルダを開く…」を選びます。サイドバーから書類を開き、フォルダ全体を検索できます。
5. 編集した書類を保存します。HTMLやPDFなどを作成する場合は「書き出し」メニューを使います。

### よく使うショートカット

以下は初期設定です。書式コマンドなどの割り当ては設定画面で確認・変更できます。

| 操作 | ショートカット |
| --- | --- |
| コマンドパレット | ⌘⇧P |
| 文書内を検索 | ⌘F |
| 置換画面を開く | ⌘⌥F |
| 指定行へ移動 | ⌘L |
| 見出しへ移動 | ⌘⇧O |
| ワークスペースのフォルダを開く | ⌘⌥O |
| ワークスペースのファイル名で開く | ⌘⌥P |
| フォルダ全体を検索 | ⌘⌥⇧F |
| 集中モードの切り替え | ⌘⇧J |

⌘はCommand、⌥はOption、⇧はShiftです。

### ターミナルから書類・行を開く

インストール済みのアプリ、または`./start.sh`かXcodeで一度起動してURLスキームを登録したアプリへ、書類と行番号を渡せます。

```sh
swift Tools/mktown-open.swift --line 42 ~/notes/example.md
```

ファイルURLも指定でき、行番号を省略すると書類だけを開きます。既に開いている書類は、そのウインドウを使います。URLスキームは`mktowneditor://open?url=<パーセントエンコードしたfile URL>&line=42`です。

## 追加設定が必要な機能

| 機能 | 必要なもの |
| --- | --- |
| DOCX・ODT・EPUBへの書き出し | Pandocを別途導入し、設定で指定 |
| Graphvizの図 | Graphviz実行ファイルを別途導入し、設定で指定 |
| PlantUMLの図 | PlantUML JARとJavaを別途導入し、設定で指定 |
| WordPress・GitHub Pagesへの公開 | 送信先と認証情報の設定、ネットワーク接続 |
| AI推敲・翻訳 | OpenAI APIキーと送信先の設定、ネットワーク接続 |

Mermaidと数式の描画ライブラリは同梱しています。[数式の書き方](docs/features.md#数式の書き方)も参照してください。リモート画像の読み込みと外部ページの題名取得は、設定で有効にした場合に行います。

## テスト

すべてのSwiftユニットテストを実行します。

```sh
swift test
```

Xcodeでは`MKTownEditor`スキームでProduct > Testを選ぶと、アプリをホストにして同じテストを実行できます。アプリをホストにした実行ではイベントの区切りでUndoグループが閉じないため、複数のUndo単位を扱うテストは[テストでのUndoグループの区切り方](docs/undo-grouping-in-tests.md)に従って書きます。

CIと同じチェック（Pythonのスクリプトテスト、Swiftの全ユニットテスト、Releaseビルド）を実行する場合は、次のコマンドを使います。Python 3が必要です。

```sh
bash Tools/ci.sh
```

CIでは`Package.resolved`に固定した依存ライブラリを使い、テスト失敗時はReleaseビルドへ進みません。[GitHub ActionsのCI](.github/workflows/ci.yml)は`main`へのpush・Pull Request・手動実行時にmacOS 27 / Xcode 27.0で動作します。`xcode-27` runnerは公開プレビュー扱いです。実行ログはActionsの`ci-results`から7日間ダウンロードできます。

Xcodeプロジェクトの書式変更やワークフロー定義が原因で失敗した場合は、[CIの設定検査と検証方法](docs/ci-configuration-failures.md)を参照してください。

## リリース配布

`v1.0.0`などのタグをpushすると、[Releaseワークフロー](.github/workflows/release.yml)が全ユニットテストを実行し、Developer ID署名・Appleの公証済みUniversalアプリをZIPにしてGitHub Releasesのドラフトへ登録します。初回に証明書と5項目のGitHub Secretsを設定し、リリースごとにダウンロードしたアプリを確認して公開します。

## 開発用ファイル

| 場所 | 内容 |
| --- | --- |
| [`Sources/MKTownEditor`](Sources/MKTownEditor) | アプリ本体と同梱リソース |
| [`Tests/MKTownEditorTests`](Tests/MKTownEditorTests) | Swiftのユニットテスト |
| [`Support`](Support) | Info.plistとアプリアイコン（Icon Composerの書類。[アプリアイコン](docs/app-icon.md)を参照） |
| [`Tools`](Tools) | CI、アプリバンドルの組み立て、スクリプトのテスト、書類を開くCLI |
| [`Package.swift`](Package.swift) | Swift Packageの構成と依存ライブラリ |
| [`docs`](docs) | 機能ガイドなどの公開ドキュメント |

## ライセンス

[MIT License](LICENSE)。同梱する[Mermaid](Sources/MKTownEditor/Resources/Mermaid-LICENSE.txt)と依存ライブラリの[SwiftMath](https://github.com/mgriebling/SwiftMath)もMIT Licenseです。
コードブロックの色分けには、[swift-tree-sitter](https://github.com/tree-sitter/swift-tree-sitter)（BSD 3-Clause License）、[tree-sitter](https://github.com/tree-sitter/tree-sitter)、[tree-sitter-javascript](https://github.com/tree-sitter/tree-sitter-javascript)、[tree-sitter-typescript](https://github.com/tree-sitter/tree-sitter-typescript)、[tree-sitter-ruby](https://github.com/tree-sitter/tree-sitter-ruby)（いずれもMIT License）を使っています。著作権表示とライセンス全文は[サードパーティのライセンス](docs/third-party-licenses.md)にあります。
