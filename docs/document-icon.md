# 書類アイコン

Finderに表示されるMarkdown書類のアイコンは、用紙の形の中央にアプリアイコン（「MT」）のバッジを置き、その下に拡張子の文字「MD」を入れたものにする。この図柄はシステムが描くので、画像ファイルは用意していない。`Support/Info.plist` に、システムに描画を任せることと、バッジと文字の内容を宣言している。

## 症状

MKTownEditorを `.md` の既定アプリにしても、Finderは汎用のテキスト書類のアイコンを表示していた。用紙にアプリのバッジは付かず、ほかのテキストエディタに割り当てた書類と見分けがつかなかった。

## 原因

`Support/Info.plist` の書類タイプ（`CFBundleDocumentTypes`）と型宣言（`UTImportedTypeDeclarations`）に、アイコンに関するキーがなかった。キーがないと、システムは親の型 `public.plain-text` のアイコンを使う。

検証用のアプリ（後述）で宣言を変えて、macOS 27.0.1で `NSWorkspace.icon(forFile:)` が返すアイコンを比べた結果は次のとおりである。

| 宣言 | 書類のアイコン |
| --- | --- |
| アイコンのキーなし | `public.plain-text` の汎用アイコン |
| 書類タイプに `CFBundleTypeIconSystemGenerated` だけ | 変化なし（汎用アイコンのまま） |
| `CFBundleTypeIconSystemGenerated` と、アプリ自身の型宣言の `UTTypeIcons`（`UTTypeIconBadgeName` = `AppIcon`、`UTTypeIconText` = `md`） | 用紙の中央にアプリアイコンのバッジ、その下に「MD」 |
| 書類タイプに `CFBundleTypeIconFile` = `AppIcon` | アプリアイコンそのもの。用紙の形にならない |

`CFBundleTypeIconSystemGenerated` は、システムにアイコンの生成を任せるという指定にすぎない。バッジと文字は、既定アプリが持つ型宣言の `UTTypeIcons` から読まれる。フラグだけでは描く材料がないため、汎用アイコンのままになる。

## 採用した宣言

3番目の組み合わせを採用した。CotEditorとObsidianも同じ方式を使っている。

```xml
<!-- CFBundleDocumentTypes の Markdown Document -->
<key>CFBundleTypeIconSystemGenerated</key>
<true/>

<!-- UTImportedTypeDeclarations の net.daringfireball.markdown -->
<key>UTTypeIcons</key>
<dict>
	<key>UTTypeIconBadgeName</key>
	<string>AppIcon</string>
	<key>UTTypeIconText</key>
	<string>md</string>
</dict>
```

`UTTypeIconBadgeName` は、アプリの `Assets.car` に入っている画像の名前である。`actool` は `Support/AppIcon.icon` を `AppIcon` という名前で `Assets.car` に書き出すので（[アプリアイコン](app-icon.md)）、アプリアイコンの名前 `CFBundleIconName` と同じ値を書く。`UTTypeIconText` は小文字で書いても、用紙には大文字の「MD」で描かれた。

`CFBundleTypeIconFile` でアプリアイコンを指定する方式は採らなかった。書類がアプリと同じ見た目になり、Finderでアプリ本体と書類を区別しにくくなるためである。

## Human Interface Guidelinesとの関係

HIGは、macOSの書類アイコンを右上の角が折れた用紙の形で表し、その上にアプリのバッジと拡張子の文字を載せる構成を示している。この形をシステムに生成させると、用紙の形、バッジの位置、文字の書体と色がほかのアプリの書類と揃う。画像を自作すると、これらを自分で合わせ続ける必要がある。

## 検証方法

書類アイコンは、その型の既定アプリの宣言から描かれる。ユーザーの `.md` の既定アプリを変えずに確かめるため、ビルドしたバンドルのコピーに一意な型と拡張子を宣言させ、その型の既定アプリにして描画する。

1. `Tools/make-app-bundle.sh "$(swift build --configuration release --show-bin-path)" .build/iconprobe/Probe.app` でバンドルを作る。`Info.plist` は変更後の `Support/Info.plist` から、`Assets.car` は `actool` から来るので、出荷するものと同じ組み合わせになる。
2. コピーの `Contents/Info.plist` を PlistBuddy で次のとおり書き換える。`CFBundleTypeIconSystemGenerated` と `UTTypeIcons` は検証対象なので変えない。

   | キー | 書き換え |
   | --- | --- |
   | `CFBundleIdentifier` | 一意な値 |
   | `CFBundleDocumentTypes` の `LSItemContentTypes` | 新しい一意な型の識別子だけにする（`public.plain-text` も外す） |
   | `CFBundleDocumentTypes` の `CFBundleTypeExtensions` | 新しい一意な拡張子だけにする |
   | `CFBundleDocumentTypes` の `LSHandlerRank` | `Owner` |
   | `UTImportedTypeDeclarations` の `UTTypeIdentifier` | 上と同じ型の識別子 |
   | `UTImportedTypeDeclarations` の `UTTypeTagSpecification` | 上と同じ拡張子だけにする（MIMEタイプも外す） |
   | `CFBundleURLTypes`、`NSServices` | 削除する |

3. `codesign --force -s -` で署名し直し、`lsregister -f` で登録する（`lsregister` は `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/` にある）。
4. その拡張子のファイルを作り、`NSWorkspace.shared.icon(forFile:)` の画像をPNGに書き出して目で確かめる。あわせて `UTType(filenameExtension:)` と `NSWorkspace.shared.urlForApplication(toOpen:)` で、型が新しい識別子に解決され、既定アプリが検証用のアプリになっていることを確かめる。
5. `lsregister -u` で登録を解除し、`lsregister -dump` に検証用の識別子が残っていないことを確かめてから、検証用のアプリを削除する。

この手順には落とし穴が3つある。

| 落とし穴 | 内容と対処 |
| --- | --- |
| 一時フォルダのアプリは既定アプリにならない | `/tmp`、`/private/tmp`、`/var/folders` に置いた検証用アプリは、既定アプリに選ばれなかった。`lsregister -dump` では、一時フォルダのアプリの `bundle flags` に `in-temp-dir` が付く。リポジトリ内のGit管理外のフォルダ（`.build/` の下）に置く。なお `.build/` に置いた未起動の検証用アプリにも `launch-disabled` が付いたが、こちらは既定アプリになり、アイコンも描かれた |
| アイコンは型ごとにキャッシュされる | 一度描画した型と拡張子は、宣言を変えて登録し直しても古いアイコンが返ることがある。宣言を変えるたびに、使ったことのない型の識別子と拡張子を使う |
| ユーザーの既定アプリを変えない | 実際の `.md`（`net.daringfireball.markdown`）や `public.plain-text` を検証用アプリに割り当てると、ユーザーの既定アプリが変わる。検証用アプリには一意な型だけを宣言させ、実在の型を一つも主張させない。検証の前後で `.md` と `.txt` の既定アプリが変わっていないことも確かめる |

## テスト

- `Tests/MKTownEditorTests/ApplicationBundleInfoTests.swift` の `testMarkdownDocumentsAskForASystemGeneratedIconBadgedWithTheAppIcon`：Markdownを扱う書類タイプが `CFBundleTypeIconSystemGenerated` を持ち、`CFBundleTypeIconFile` を持たないこと、型宣言の `UTTypeIcons` が文字 `md` と、`Support/` に実在するIcon Composerの書類の名前をバッジに指定していることを確認する。
- `Tools/test_make_app_bundle.py` の `test_markdown_document_icon_is_badged_with_the_compiled_app_icon`：`make-app-bundle.sh` が作ったバンドルで、バッジ名が `actool` の出力した `CFBundleIconName` と一致することを確認する。同じファイルの `test_compiles_the_app_icon_as_the_xcode_build_does` が、`CFBundleIconName` がXcodeプロジェクトの `ASSETCATALOG_COMPILER_APPICON_NAME` と一致し、その名前の画像が `Assets.car` にあることを確認するので、Xcodeプロジェクトのビルドでもバッジ名と画像名が一致する。
- `Tools/test_mobile_project.py` の `test_mobile_and_desktop_declare_the_same_markdown_type`：Mac版とiOS版の型宣言を比べる際に、Mac版だけが持つ `UTTypeIcons` と `CFBundleTypeIconSystemGenerated` を除く。除く前に、Mac版がそれらを持っていることも確かめる。

## 未確認の点

| 項目 | 状況 |
| --- | --- |
| Finderの画面 | `NSWorkspace.icon(forFile:)` が返す画像で確かめた。Finderのウインドウに表示されたアイコンは見ていない |
| 実際の `.md` | 検証用の一意な型で確かめた。実際の `.md` をMKTownEditorに割り当てた状態では確かめていない |
| macOS 14〜15 | macOS 27.0.1でだけ確かめた。`Assets.car` を読まない古いmacOSでバッジがどう描かれるかは確かめていない |
| `.txt` | `public.plain-text` はシステムの型で、アプリは型宣言を持たない。MKTownEditorを `.txt` の既定アプリにしても、汎用のテキスト書類のアイコンのままと考えられる |
| iOS | 対象外。`Support/Mobile-Info.plist` にはアイコンのキーを足していない |
