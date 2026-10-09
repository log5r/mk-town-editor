# アプリアイコン

アプリアイコンは、Icon Composerの書類 `Support/AppIcon.icon` で管理する。白い背景に、#26325C の「MT」の文字を置いただけの図柄で、文字にはLiquid Glassの効果（ガラスの質感、光沢、半透明）をかけている。

## 書類の構成

`.icon` はフォルダで、次の2つを含む。どちらもテキストなので、差分をGitで確認できる。

| 場所 | 内容 |
| --- | --- |
| `icon.json` | 背景色、レイヤーの重なり、ガラス効果、影、対応プラットフォーム（macOSのみ） |
| `Assets/MT.svg` | 「MT」の図形。1024×1024の画面に、塗り #26325C のパス1本で描く |

「MT」はフォントの文字ではなく、直線だけで組んだ図形である。システムフォント（SF Proなど）はライセンスがUIのモックアップ用途に限られていて、アイコンに使えるかがはっきりしないため、フォントを使わずに描いた。SVGに `<text>` を書いた場合、描画するマシンのフォントに見た目が左右されることも避けられる。

図柄を変えるときは、Icon Composerで `Support/AppIcon.icon` を開いて編集し、保存する。Xcodeのプロジェクトナビゲータから開くこともできる。

## ビルドへの組み込み

アプリのビルド方法は2通りあり、どちらも `actool` で同じ書類を変換する。

- **Xcodeプロジェクト**：`AppIcon.icon` をアプリターゲットのリソースに入れ、ビルド設定 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` を指定している。
- **`Tools/make-app-bundle.sh`**（`start.sh` が使う）：SwiftPMは `.icon` を変換しないので、スクリプトが `xcrun actool` を直接呼ぶ。

`actool` は `Contents/Resources` に次の2つを出力する。

- `Assets.car`：macOS 26以降が読む、レイヤー構成を保ったアイコン。外観（ライト、ダーク、クリア、ティント）に応じてシステムが描画する。
- `AppIcon.icns`：macOS 14〜15向けの、描画済みのアイコン。

あわせて `actool` は、Info.plistに足すキー（`CFBundleIconFile` と `CFBundleIconName`、どちらも `AppIcon`）を部分Info.plistとして出力する。Xcodeはこれを自動で統合し、`make-app-bundle.sh` は `plutil` で同じ2つのキーを書き込む。そのため `Support/Info.plist` にはアイコンのキーを書いていない。

変換に失敗した場合、`make-app-bundle.sh` は `actool` のメッセージを表示して、バンドルを作らずに終了する。`.icon` の変換にはXcode 26以降の `actool` が必要である。

## 見た目の確認

Icon Composerに付属する `ictool` で、外観ごとの画像を書き出せる。

```bash
"/Applications/Icon Composer.app/Contents/Executables/ictool" Support/AppIcon.icon --export-image --output-file /tmp/AppIcon-Dark.png --platform macOS --rendition Dark --width 256 --height 256 --scale 1
```

`--rendition` には `Default`、`Dark`、`ClearLight`、`ClearDark`、`TintedLight`、`TintedDark` を指定できる。`Tinted*` では `--tint-color` と `--tint-strength` も指定する。

## 色と外観についての注意

ガラス効果をかけると、文字は光沢と半透明の分だけ #26325C より明るく描かれ、下に行くほど明るくなる。レイヤーの `glass` を `false` にすると、`actool` が書き出す画素は #26325C（RGB 38, 50, 92）に一致する。採用した図柄は、色の正確さよりもLiquid Glassの質感を優先している。

ダーク外観では背景が暗い色に置き換わるため、紺の文字のコントラストが低くなる。改善するには、`icon.json` のレイヤーに `fill-specializations` を書き、ダーク外観だけ文字を明るい色で塗る方法がある。

## テスト

- `Tools/test_app_icon.py`：書類が参照する画像がそろっていること、背景色・文字色・ガラス効果の設定を確認する。
- `Tools/test_make_app_bundle.py`：`make-app-bundle.sh` が `Assets.car` と `AppIcon.icns` を出力し、Info.plistのアイコン名がXcodeプロジェクトの設定と一致すること、書類がないと失敗することを確認する。
- `Tools/test_xcode_project.py`：Xcodeのアプリターゲットが書類をリソースに含み、`make-app-bundle.sh` と同じアイコン名を使うことを確認する。
