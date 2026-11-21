# SwiftPMのビルドがLiquid Glassで描かれない（SDK版の記録）

2026-11-22に調査。macOS 27.2、Xcode 27.2（Swift 6.4.2）で確認した。

## 症状

`./start.sh`（`swift build` のReleaseビルドを `.app` にまとめる）で起動したアプリは、macOS 26以降でもツールバーのボタンや表示モードのセグメントにLiquid Glassのカプセルが付かず、以前のmacOSと同じ見た目（互換表示）になった。同じソースをXcodeでビルドしたアプリはLiquid Glassで描かれる。

## 原因

AppKitは、実行ファイルの `LC_BUILD_VERSION` に記録されたSDKの版を見て、新しい見た目と互換表示を切り替える（リンクしたSDKが古いアプリを、古い見た目のまま動かすため）。SwiftPMで作った実行ファイルは、SDK 27.2でコンパイルしているのに、SDKの版としてデプロイターゲットの14.0を記録していた。

```text
$ vtool -show-build .build/release/MKTownEditor      # 修正前
    minos 14.0
      sdk 14.0
$ vtool -show-build build/InstallDerivedData/Build/Products/Release/MKTownEditor.app/Contents/MacOS/MKTownEditor
    minos 14.0
      sdk 27.2
```

SDKの版はリンカーの `-platform_version macos <minos> <sdk>` で決まり、その値はclangが渡す。

1. SwiftPM（swiftbuild）は、ツールチェーン内の `swiftc` を絶対パスで呼び、`-sdk .../MacOSX27.2.sdk` を付けてリンクする。
2. swift-driverはリンクにclangを使い、SDKを `--sysroot` で渡す。
3. clangは、SDKの版（`SDKSettings.json`）を `-isysroot` か環境変数 `SDKROOT` からしか読まない。`--sysroot` だけでは版がわからず、デプロイターゲットの版を使う。

```text
clang main.o --target=arm64-apple-macos14.0 --sysroot <SDK> -###   →  "-platform_version" "macos" "14.0.0" "14.0.0"
clang main.o --target=arm64-apple-macos14.0 -isysroot <SDK> -###   →  "-platform_version" "macos" "14.0.0" "27.2"
```

端末で `swiftc` を直接実行すると再現しない。`/usr/bin/swiftc` などは `xcrun` のシムで、環境変数 `SDKROOT` を設定してから本物を起動するためである（`/usr/bin/python3` も同じシムで、その子プロセスでも再現しない）。調査中、同じリンクコマンドがシェルからは14.0、Pythonからは27.2になったのはこのためだった。`SDKROOT=... swift build` としても直らなかった（SwiftPMがリンクの工程にこの変数を渡していないと考えられる）。

## 対処

`start.sh` は、clangのリンクにだけ `-isysroot` を渡す。

```sh
sdk=$(xcrun --sdk macosx --show-sdk-path)
swift build --configuration release \
    -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk"
```

`-Xclang-linker` はswift-driverがリンクのときだけclangへ渡す引数で、コンパイルには影響しない。`--show-bin-path` にも同じ引数を渡し、同じビルドの成果物を指すようにした。`-Xlinker -platform_version ...` を直接渡す方法は、版をスクリプトに書くことになり、clangが渡す値と重複するため採らなかった。ビルド後に `vtool -set-build-version` で書き換える方法も、リンクの結果を後から変えるため採らなかった。

`Tools/make-app-bundle.sh` は、実行ファイルが記録したSDKのメジャー版が、使っているSDK（`xcrun --sdk macosx --show-sdk-version`）より古ければ、バンドルを作らずに失敗する。`start.sh` 以外の経路で `-isysroot` を付け忘れても、互換表示のアプリを黙って作らない。

同じ経路で `.app` を作るのは `start.sh` だけである。`install.sh` と `Tools/build-release.sh` は `xcodebuild` でビルドし、XcodeはSDKの版を正しく記録する。CIの `Tools/ci.sh release` は `swift build` で実行ファイルを作るだけで、アプリとして起動しない。

## 検証

- `swift build --configuration release` に上の引数を付けると、`vtool -show-build` の `sdk` が27.2になった（付けないと14.0）。
- SDK 27.2を記録したReleaseビルドを、バンドルIDを変えたコピーとして起動すると、ツールバーのボタン・メニュー・表示モードのセグメントがLiquid Glassのカプセルで描かれた。修正前（SDK 14.0）のコピーは、同じソースでも従来の見た目だった。どちらもツールバーの不透明な背景（`toolbarBackground`）を指定したままの版で比べた。
- `Tools/test_start.py` は `start.sh` が `-isysroot` の引数で2回 `swift build` を呼ぶことを、`Tools/test_make_app_bundle.py` はSDK 14.0を記録した実行ファイル（`vtool` で作る）を拒否することを確かめる。

## 調べ方

- 記録されたSDKの版：`vtool -show-build <実行ファイル>` または `otool -l <実行ファイル> | grep -A4 LC_BUILD_VERSION`。
- clangがリンカーに渡す値：リンクコマンドに `-Xclang-linker -###` を付けて実行し、`-platform_version` を見る。SwiftPMのリンクコマンドは `swift build -v` の出力の `Link MKTownEditor` の次の行にある。
- シムの影響を除くには、ツールチェーンの `swiftc` / `clang` を絶対パスで呼び、`SDKROOT` を設定しない環境で試す。
