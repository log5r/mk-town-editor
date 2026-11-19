# iPhone・iPadへのインストール（`install-ios.sh`）

`install-ios.sh`は、iOS版をReleaseビルドし、Xcodeでペアリング済みのiPhone・iPadへインストールする。Xcodeで「Connect via network」を有効にした端末なら、同じネットワーク上にあればケーブルなしでインストールできる。

## 事前準備

1. 端末をMacにケーブルで接続し、Xcodeの Window > Devices and Simulators で信頼・ペアリングする。
2. 同じ画面で端末の「Connect via network」をオンにする。
3. 端末の「設定」>「プライバシーとセキュリティ」>「デベロッパモード」をオンにする。
4. Xcodeの Settings > Accounts に開発用のApple Accountを追加し、[ローカル署名設定](xcode-project-structure.md#ローカル署名設定)でTEAM IDを指定する。

一度もXcodeから実行していない端末は、開発用プロビジョニングプロファイルに登録されていない場合がある。その場合は、XcodeでMKTownEditorMobileをその端末へ1回実行する。

## 使い方

```sh
./install-ios.sh                         # 接続できる端末が1台ならそこへインストール
./install-ios.sh --list-devices          # ペアリング済みの端末と接続状態を表示
./install-ios.sh --device "Work iPhone"  # 名前・UDID・CoreDevice IDで指定
./install-ios.sh --launch                # インストール後に起動（ロック解除が必要）
./install-ios.sh --team ABCDE12345       # TEAM IDを指定
```

TEAM IDは`--team`、環境変数`APPLE_TEAM_ID`、`Support/Signing.local.xcconfig`などのプロジェクト設定の順に参照する。どれもなければビルド前に終了する。`--app PATH`を指定すると、ビルド済みの`.app`をそのままインストールする。`--`以降は`KEY=VALUE`形式のビルド設定として`xcodebuild`へ渡す。

インストールは既存のアプリを置き換える。アプリのデータは残る。

## 動作

1. `xcrun devicectl list devices --json-output`で端末を取得する。対象は、実機（`reality: physical`）でiOS系の、ペアリング済み（`pairingState: paired`）の端末である。接続状態が`unavailable`の端末は除く。
2. 端末を特定できない場合は、ビルド前に終了して候補を表示する。デベロッパモードが`disabled`の端末も同様に終了する。
3. `xcodebuild -destination 'generic/platform=iOS' -allowProvisioningUpdates build`でビルドする。成果物は`build/InstallDerivedData-iOS`に出力する。
4. `xcrun devicectl device install app`でインストールする。`--launch`を指定した場合は、続けて`devicectl device process launch --terminate-existing`で起動する。

ビルドの全ログは、実行ごとに`.build-logs/install-ios-<日時>-<PID>.log`へ保存する。`xcsift`があれば`xcsift -f toon -w`で整形して表示し、なければそのまま表示する。

## devicectlのJSON

Xcode 27の`devicectl`は、端末の情報を`properties`辞書（`hardware`・`connection`・`state`）に出力する。従来の`hardwareProperties`・`connectionProperties`・`deviceProperties`は非推奨と表示されるが、出力はまだ残っている。スクリプトは両方の形式を読む。

`devicectl list devices`はシミュレータも返す（`reality: simulated`）。ネットワーク経由の実機は、使える状態なら接続状態が`disconnected`（表では「available (paired)」）になる。接続は`devicectl`がコマンド実行時に確立する。

## うまくいかないとき

- 「接続できるiPhone・iPadがありません」：端末がスリープから復帰しているか、Macと同じネットワークにいるかを確認する。XcodeのDevices and Simulatorsを開くと、端末が見つかる場合がある。
- 署名エラー：XcodeのAccountsにチームのアカウントがあるか、TEAM IDが正しいかを確認する。全ログは`.build-logs/`に残る。
- 起動に失敗する：ロック中の端末ではアプリを起動できない。インストールは完了しているので、端末のロックを解除してホーム画面から起動する。

## 検証

`Tools/test_install_ios.py`では、偽の`xcrun`・`xcodebuild`・`xcsift`を使って次の点を検査する。端末の選択と除外、新旧のJSON形式、TEAM IDの優先順位、ビルド前の失敗、ログの保存、インストールと起動のコマンドである。2026-11-19に、実際の`devicectl`で一覧表示とシミュレータの除外を確認した。実際の`xcodebuild -showBuildSettings -json`の出力から成果物のパスとTEAM IDを読めることも確認した。実機へのインストールは、接続できる端末がなかったため未検証。
