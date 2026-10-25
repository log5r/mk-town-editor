# 単一Xcodeプロジェクトの構成

`MKTownEditor.xcodeproj`でmacOSとiOSのアプリ・ユニットテストを管理する。macOSは`MKTownEditor`、iOSは`MKTownEditorMobile`の共有スキームを選ぶ。各スキームのTestアクションは、そのOSのアプリをホストとするテストターゲットを実行する。

## 統合時の判断

iOS版の追加時には別のプロジェクトを作っていたが、OSごとのアプリを独立したターゲットとして既存プロジェクトに置けるため、プロジェクトを分ける必要はなかった。画面や依存ライブラリの違いはターゲットで管理する。

SDK・対応プラットフォーム・最低OSバージョンは各ターゲットのDebugとReleaseに設定する。プロジェクト共通の設定には置かず、macOS向けの設定がiOSターゲットに継承されることを防ぐ。元のiOSプロジェクトの共通コンパイラ設定は、iOSのアプリ・テスト両ターゲットへ移した。

`MarkdownDocument.swift`、`MarkdownTextFormat.swift`、`Support/AppIcon.icon`は、両アプリのビルドフェーズから同じファイル参照を使う。iOSの画面・解析・テストはそれぞれのディレクトリのグループで管理する。Bundle IdentifierとInfo.plistはOSごとに保持する。

## 検査

`Tools/test_xcode_project.py`は、ルートのプロジェクトが1つであること、4ターゲットと成果物の登録、OS設定の分離、両スキームのビルド・起動・プロファイル・テストの参照先を検査する。`Tools/test_mobile_project.py`は、グループの相対パスを解決してソースの網羅性と共有参照、iOSテストのホストと依存関係を検査する。CIも統合先のプロジェクトを指定する。

全ユニットテストの実行方法は[README](../README.md#テスト)、iOSの実行方法は[iOS版の対応](iphone-duo-support.md)を参照。AIエージェントはビルド・テスト時に[ログ保存方針](../AGENTS.md#aiエージェントのビルドテストログ)を適用する。
