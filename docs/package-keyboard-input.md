# Package実行時のキーボード入力不能の調査

2026-09-29、Xcodeで `Package.swift` を開いて実行すると、本文をクリックしてカーソルは出るが文字を入力できず、Command+Nで別のアプリが前面に出るという報告があった。コンソールには `Unable to obtain a task name port right for pid 416: (os/kern) failure (0x5)` が表示されていた。

## 推定原因と起動方法

Packageから起動した実行ファイルがアクティブ化されず、キーボード入力が別のアプリに送られている可能性が高い。[Appleの仕様](https://developer.apple.com/documentation/appkit/nsapplication/activationpolicy-swift.enum/prohibited)では、Info.plistのない単体実行ファイルの既定のactivation policyは `prohibited` である。今回のプロセスの実際のpolicyは未取得なので、症状と実行構成からの推定である。

通常の起動には `MKTownEditor.xcodeproj` を開き、`MKTownEditor` スキームでRunする。こちらは `com.apple.product-type.application` のアプリターゲットで、Debug・Releaseともに `Support/Info.plist` を使用する。Packageで起動したプロセスはXcodeのStopで停止してから切り替える。

切替後は本文をクリックして英数字・日本語を入力し、Command+Nでこのアプリの新規書類が開くことを確認する。この切替によるユーザー環境での解消は、調査時点では未確認。

## 切り分け結果

- 本文の `isEditable` はファイル移動中の書類ロックに連動する。URLのない新規書類ではロックされない。
- サイズゼロで生成した入力ビューの高さ不足も疑ったが、AppKitのレイアウト後には表示領域を覆い、中央のクリックも入力ビューに届いた。`EditorTextStyleTests.testInitiallyEmptyEditorCoversViewportForMouseInput` で確認した。このテストはアプリ全体のアクティブ化を検証するものではない。
- task name portのログだけでは、どのプロセスへの権限取得が失敗したか、その失敗が入力不能に関係するかは判断できない。ログの解消を目的にSandboxや署名設定を変更する根拠はない。

関連する起動構成と型宣言の調査は [swiftui-update-warnings.md](swiftui-update-warnings.md) を参照。
