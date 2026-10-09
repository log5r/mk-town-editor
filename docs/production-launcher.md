# `start.sh` のアプリバンドル起動

`./start.sh` は、Swift PackageのReleaseビルドから最小構成のアプリバンドル `.build/MKTownEditor.app` を組み立て、`open` で起動する。以前は `swift run --configuration release MKTownEditor` で実行ファイルを直接起動していたため、`Support/Info.plist` の宣言がどれも効いていなかった（Issue #47）。

## 実行ファイルを直接起動したときに欠けていたもの

Swift Packageの実行ファイルはアプリバンドルではなく、Info.plistを持たない。Launch ServicesはInfo.plistを持つバンドルだけを登録するため、次の機能が使えなかった。

- URLスキーム `mktowneditor://` が登録されず、`Tools/mktown-open.swift` は常に「launch the app once to register its URL scheme」で失敗した。
- Markdownの書類タイプとUTI、サービスメニューの「選択テキストをMarkdown書類に保存」が登録されなかった。
- `NSLocalNetworkUsageDescription` と `NSBonjourServices` がないため、macOS 15以降では共同編集のMultipeer Connectivityによる探索がローカルネットワークのプライバシー制御で拒否された。
- Dockとメニューバーには実行ファイル名が表示された。キー入力が届かない問題は `ApplicationActivation` で回避していた（[`swift run` で起動したときに文字が入力できない問題](package-launch-activation.md)）。

## 起動の流れ

`start.sh` は次の順に処理する。

1. 第1引数が `rebuild` なら `swift package clean` を実行する。
2. `swift build --configuration release` でビルドし、`--show-bin-path` で成果物のディレクトリを得る。
3. `Tools/make-app-bundle.sh` でアプリバンドルを組み立て、アドホック署名する。
4. `open -a .build/MKTownEditor.app` で起動する。残りの引数に書類を渡すと、その書類を開く。相対パスは `start.sh` を実行したディレクトリを基準に解決する。存在しないパスやディレクトリを渡すと、ビルドせずに使い方を表示して終了する。

```sh
./start.sh                      # 差分ビルドして起動
./start.sh rebuild              # 成果物を削除してから起動
./start.sh notes/a.md b.md      # 起動して書類を開く
./start.sh rebuild notes/a.md   # 両方を指定する
```

`open` はアプリを起動するとすぐに戻るため、アプリの標準出力はターミナルに表示されない。ログは「コンソール」アプリか `log stream --process MKTownEditor` で確認する。

## バンドルの構成

`Tools/make-app-bundle.sh PRODUCTS_DIR APP_PATH` は、ビルド済みの成果物から次の構成を作る。

| 場所 | 内容 |
| --- | --- |
| `Contents/Info.plist` | `Support/Info.plist` のビルド設定変数を展開したもの |
| `Contents/PkgInfo` | `APPL????` |
| `Contents/MacOS/MKTownEditor` | Releaseビルドの実行ファイル |
| `Contents/Resources/*.bundle` | SwiftPMのリソースバンドル（`MKTownEditor_MKTownEditor.bundle` と `SwiftMath_SwiftMath.bundle`） |
| `Contents/Resources/*.lproj` | アプリのリソースバンドルからコピーした文字列テーブル |
| `Contents/Resources/Assets.car`、`AppIcon.icns` | `Support/AppIcon.icon` を `actool` で変換したアプリアイコン（[アプリアイコン](app-icon.md)） |

Info.plistの変数は、Xcodeプロジェクトのアプリターゲットと同じ値に展開する。`$(EXECUTABLE_NAME)` と `$(PRODUCT_NAME)` は `MKTownEditor`、`$(PRODUCT_BUNDLE_IDENTIFIER)` は `com.mktown.editor`、`$(MACOSX_DEPLOYMENT_TARGET)` は `14.0` になる。スクリプトが知らない変数が `Support/Info.plist` に増えた場合は、展開漏れのまま登録されないように、バンドルを作らずに失敗する。値がXcodeプロジェクトとずれた場合は `Tools/test_make_app_bundle.py` が失敗する。

組み立ては出力先と同じディレクトリの一時ディレクトリで行い、署名まで終えてから既存のバンドルと置き換える。起動中のアプリが使っている署名済み実行ファイルをその場で上書きすると、macOSが署名の不一致でそのプロセスを終了させるためである。

### リソースバンドルの置き場所

`Bundle.module` の実装はSwiftPMが生成し、ビルドシステムによって探索先が異なる。Swift 6.4の既定であるswiftbuildビルドシステムは、`Bundle.main.resourceURL`（アプリでは `Contents/Resources`）、モジュールを含むバンドルの `resourceURL`、`Bundle.main.bundleURL` の順に探す。そのため、リソースバンドルを `Contents/Resources` に置けば見つかる。

`--build-system native` の生成コードは `Bundle.main.bundleURL`（`.app` の直下）とビルドディレクトリの絶対パスだけを探す。`.app` の直下にファイルを置くと署名が通らないため、この場合はビルドディレクトリの絶対パスで見つかることになる。`.build` を削除しない限り動くはずだが、実機ではswiftbuildでだけ確認している。

### UIの言語

SwiftUIの `Text("…")` と `String(localized:)` は、バンドルを指定しないと `Bundle.main` から文字列を探す。SwiftPMは `Localizable.xcstrings` を `en.lproj/Localizable.strings` にコンパイルしてリソースバンドルへ入れるので、そのままでは `.app` から英語訳が見つからない。そこで `*.lproj` を `Contents/Resources` にもコピーする。

`CFBundleDevelopmentRegion` は、Xcodeプロジェクトの `DEVELOPMENT_LANGUAGE`（`en`）ではなく、カタログのソース言語である `ja` にする。カタログのキーは日本語の原文なので `ja.lproj` は生成されない。開発地域を `en` にすると、日本語環境でも `en.lproj` が選ばれ、アプリのメニューは英語になる。開発地域を `ja` にし、`CFBundleLocalizations` に `ja` と `en` を並べると、日本語環境では標準メニュー（ファイル、編集など）も日本語になり、英語環境ではアプリのメニューも英語になる。

## Xcodeプロジェクトのテストターゲット

`MKTownEditor.xcodeproj` に、アプリをホストとするユニットテストターゲット `MKTownEditorTests` と、それをテスト対象に含む共有スキームを追加した。テストのソースはファイルシステム同期グループで `Tests/MKTownEditorTests` を参照するため、テストファイルを追加してもプロジェクトを編集する必要はない。アプリターゲットのソースは従来どおり1ファイルずつ列挙しているので、`Sources/MKTownEditor` にファイルを追加したときはプロジェクトにも追加する。追加し忘れると `Tools/test_xcode_project.py` が失敗する（`ApplicationActivation.swift` が漏れてXcodeのビルドが壊れていたため、このテストを置いた）。

共有スキームでは、DebugビルドがIntel向けのスライスも作り、SwiftMathのモジュールが見つからずに失敗した。プロジェクトのDebug設定に `ONLY_ACTIVE_ARCH = YES` を加え、実行中のMacのアーキテクチャだけをビルドする。

Xcodeでテストを実行する場合は `MKTownEditor` スキームでProduct > Testを選ぶ。コマンドラインでは次のように実行する。

```sh
xcodebuild -project MKTownEditor.xcodeproj -scheme MKTownEditor -configuration Debug \
    CODE_SIGNING_ALLOWED=NO test -only-testing:MKTownEditorTests/ApplicationBundleInfoTests
```

Xcodeのテストは `SWIFT_PACKAGE` を定義しないビルドで動くため、`#if SWIFT_PACKAGE` で分岐するコード（書類タイプ、Mermaidのリソース探索）はSwiftPMのテストと別の経路を通る。CIは従来どおり `swift test` だけを実行する。

## 制約

- **アドホック署名**：開発者IDで署名していないため、配布には使えない。手元のMacで起動するためだけの署名である。ビルドのたびに署名が変わるので、ローカルネットワークの許可を再度求められる可能性がある。
- **起動中のアプリ**：同じバンドルのアプリが起動中だと、`open` は既存のプロセスを前面に出すだけで、新しいビルドは起動しない。`start.sh` はこの場合に警告を表示する。新しいビルドを試すには、先にアプリを終了する。
- **同じバンドルIDの複数登録**：Xcodeのビルド（DerivedData内）と、ワークツリーごとの `.build/MKTownEditor.app` はどれも `com.mktown.editor` として登録される。URLスキームや書類の関連付けがどのコピーに渡るかはLaunch Servicesが決めるので、複数のコピーがあると意図しないビルドが開く場合がある。
- **Info.plistの文言**：`NSLocalNetworkUsageDescription` とサービスメニューの項目名は日本語だけで、`InfoPlist.strings` による英語訳はない。
- **Xcodeビルドの言語**：Xcodeプロジェクトの `DEVELOPMENT_LANGUAGE` は `en` のままで、Xcodeからビルドしたアプリは `-AppleLanguages '(ja)'` を指定してもメニューがすべて英語になった（2026-10-08に確認）。このリポジトリの作業範囲では `start.sh` のバンドルだけを `ja` にし、Xcode側の設定は変えていない。
- **`swift run` の直接起動**：`swift run MKTownEditor` は引き続き実行ファイルを直接起動するので、Info.plistに依存する機能は使えない。`ApplicationActivation` によるキー入力の回避はこの起動方法のために残している。

## 検証

- `python3 -B -m unittest discover -s Tools -p 'test_*.py'` で、`start.sh` の引数処理と呼び出し順、バンドルの構成、Info.plistの展開とXcodeプロジェクトとの一致、アプリアイコンの変換、文字列テーブルのコピー、アドホック署名、テストターゲットとスキームの設定を確認する。GUIは起動しない。
- `ApplicationBundleInfoTests` で、`Support/Info.plist` がURLスキーム、ローカルネットワークの利用目的、TCPとUDPの両方のBonjourサービス型、書類タイプ、サービスメニューのメッセージを宣言し、それぞれがコード側の値と一致することを確認する。
- 2026-10-08に実機で次を確認した。
  - `./start.sh <書類>` で起動したプロセスは `lsappinfo list` で `type="Foreground"`、`bundleID="com.mktown.editor"` になり、書類のウインドウが開いた。
  - 書類内の数式（SwiftMathのフォント）とMermaidの図（アプリのリソースバンドル）がプレビューに描画された。
  - 起動後に `swift Tools/mktown-open.swift --line 6 <書類>` が成功した。
  - `open -a .build/MKTownEditor.app --args -AppleLanguages '(en)'` ではメニューが「File, Edit, View, Move, Focus Mode, …」になり、`'(ja)'` では「ファイル, 編集, 表示, 移動, 集中モード, …」になった。実行ファイルを直接起動した場合は「File, Edit, View, 移動, 集中モード, …」と混在していた。
  - `xcodebuild … -configuration Debug CODE_SIGNING_ALLOWED=NO build build-for-testing` が成功し、Xcodeのテストターゲットで `ApplicationBundleInfoTests` などを実行できた。`-configuration Release build` も成功した。
- ローカルネットワークの許可ダイアログと共同編集の接続は、2台の端末が必要なため実機では確認していない。
