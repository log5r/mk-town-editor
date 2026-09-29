# SwiftUI更新中の状態通知とMarkdown型宣言の警告

## 発生経路

`MarkdownTextEditor` の `makeNSView`、`updateNSView`、`dismantleNSView` は、生成・本文同期・表示切替の際に `MarkdownEditorModel` を更新する。選択復元とレイアウト変更は、AppKitの選択変更・クリップ領域変更通知も同期的に発生させる。この途中で `@Published` に代入すると、SwiftUIの画面更新中に再び変更通知が送られ、`Publishing changes from within view updates is not allowed` が出る。メインスレッド上でも発生するため、`@MainActor` の指定だけでは解消しない。

スクロール連動プレビューの `onVisibleSourceChange` も、呼び出し先でSwiftUIの状態を書き換える。同じ理由で、クリップ領域変更通知から直接呼ばない。

## 修正方針

選択範囲・エディター接続状態・表示領域を一つの状態として管理する。ビュー更新とAppKit通知の処理中は変更を保留し、MainActorの次のタスクで最新状態だけを公開する。内部の参照には保留中の値を返すため、接続、選択復元、コマンド実行は同期的に処理できる。値が変わらない場合は公開しない。

保留中に新しい操作が入った場合も同じ状態に反映し、古い選択範囲で上書きしない。プレビューへの通知も一つにまとめ、実行時の位置を取得する。破棄したエディターの通知は取り消し、遅延処理では現在接続中のビューとの同一性を確認する。

選択変更、スクロール変更、ウインドウ接続、本文同期、エディターの生成・破棄を確認した。プレビューのテキストビューとMermaidのRepresentableも確認し、今回のモデル更新経路がないことを確認した。

## MarkdownのUTType宣言

`UTType(importedAs:)` は、アプリのInfo.plistにある `UTImportedTypeDeclarations` と対応させる。`Support/Info.plist` には既に `net.daringfireball.markdown` があり、XcodeプロジェクトのDebug・Releaseはいずれもこのファイルを使用する。

一方、Swift Packageから実行するバイナリにはこのアプリ用Info.plistがない。`SWIFT_PACKAGE` の場合は拡張子 `md` から既存の型を照会し、取得できない環境では `.plainText` を使用する。後者では保存形式もプレーンテキストになるため、通常のアプリ起動には `MKTownEditor.xcodeproj` の `MKTownEditor` スキームを使う。Xcodeのアプリ構成では従来のMarkdown型宣言を維持する。

警告の「Info.plist of Debug」という表示は、アプリバンドルではなくPackageの実行ファイルを起動している可能性を示す。ただし、この表示だけで実行構成を断定はできない。アプリ構成でも出る場合は、実際に起動した製品の `Contents/Info.plist` と実行スキームを確認する。

## 検証

- 状態通知がビュー更新中には発生せず、更新後に一度だけ発生すること。
- 内部状態と選択復元は同期的に更新され、ビュー交換と後続のナビゲーションが保持されること。
- 同じ値の再設定では通知しないこと。
- スクロール連動プレビューと表示領域の通知が遅延され、破棄後の通知が実行されないこと。
- Info.plistのMarkdown型宣言と対応拡張子、および文書型の適合性。

回帰テストは `MarkdownEditorModelTests` と `MarkdownDocumentTests` に追加した。全ユニットテストは `swift test`、アプリ構成は `xcodebuild -project MKTownEditor.xcodeproj -scheme MKTownEditor -configuration Debug CODE_SIGNING_ALLOWED=NO build` で確認する。ビルド後のアプリのInfo.plistにも宣言が含まれることを確認する。

2026-09-29の検証では、全680件のユニットテストが成功し、Debugアプリのビルドも成功した。生成されたInfo.plistにもMarkdown型宣言が含まれていた。テスト実行時にはOSの連絡先サービス接続と既存のSceneStorageテストの警告が出たが、今回提示された2種類の警告はテストログにはなかった。

XcodeのRuntime Issues表示を使う手動確認では、長い文書を開き、入力・選択・スクロール、編集／分割／プレビューの切替、文字サイズ・折返し設定の変更を行う。この手動確認は今回未実施。

## 参考

- [Apple: NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable)
- [Apple: init(importedAs:conformingTo:)](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/init(importedas:conformingto:))
- [Apple: Declaring New Uniform Type Identifiers](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/understanding_utis/understand_utis_declare/understand_utis_declare.html)
