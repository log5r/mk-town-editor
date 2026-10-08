# `swift run` で起動したときに文字が入力できない問題

`./start.sh` や `swift run MKTownEditor` で起動すると、ウインドウは表示され本文をクリックするとカーソルも出るのに、文字が入力できなかった。⌘Nを押すと別のアプリの新規書類が開くこともあった。Xcodeで `Package.swift` を開いて実行した場合も同じ症状になる。`MKTownEditor.xcodeproj` のアプリターゲットから起動した場合には起きない。

## 原因

Swift Packageがビルドする実行ファイルはアプリバンドルではなく、Info.plistを持たない。AppKitは、Info.plistのない単体実行ファイルのactivation policyを `prohibited` として起動する（[NSApplication.ActivationPolicy.prohibited](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/prohibited)）。このポリシーではウインドウを作れてもプロセスはアクティブになれないため、キー入力と⌘ショートカットは直前までアクティブだったアプリへ送られ続ける。

2026-10-08に、`start.sh` で起動したプロセスのLaunch Servicesへの登録を `lsappinfo list` で確認したところ、`type="BackgroundOnly"`、`bundleID=[ NULL ]` だった。バンドルされたアプリは `type="Foreground"` と表示される。また、実行ファイルには `__info_plist` セクションもなかった（`otool -l` で確認）。これにより、以前は推定にとどまっていた原因が確定した。

## 修正

アプリデリゲートの `applicationWillFinishLaunching` で、現在のポリシーが `prohibited` のときだけ `regular` に切り替える。SwiftUIが最初のウインドウを作る前に切り替えるため、Dockアイコンとメニューバーも表示される。バンドルされたアプリはLaunch Servicesが起動時にアクティブにするが、ポリシーを修復したプロセスは誰もアクティブにしないので、`applicationDidFinishLaunching` で自分自身をアクティブにする。

ポリシーが `regular` や `accessory` のプロセスには何もしない。Xcodeのアプリターゲットから起動した場合の動作は変わらない。

この判定と切り替えは `ApplicationActivation` にまとめ、`NSApplication` の代わりに差し替えられるプロトコル越しに操作する。これにより、ユニットテストで `prohibited` から始まるプロセスを再現できる。

## 検証

- `ApplicationActivationTests` で、`prohibited` のプロセスが起動前に `regular` へ変わり起動後に一度だけアクティブ化されること、`regular` と `accessory` には触れないこと、ポリシー変更が拒否された場合はアクティブ化しないこと、アプリデリゲートが起動通知からこの処理を呼ぶことを確認する。
- 実機では `./start.sh` で起動したあと、`lsappinfo list` の該当プロセスが `type="Foreground"` になり、本文に英数字と日本語を入力でき、⌘Nでこのアプリの新規書類が開くことを確認する。

## 残る制約

ポリシーの修復は、Info.plistがないこと自体を解消しない。Markdown文書型の宣言、URLスキーム `mktowneditor://`、サービスメニューの登録はアプリバンドルのInfo.plistに依存するため、`swift run` で起動したプロセスでは従来どおり使えないか、プレーンテキストにフォールバックする。これらが必要な場合は `MKTownEditor.xcodeproj` から起動する。
