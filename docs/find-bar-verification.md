# 標準検索バーの検索条件（S02）

確認日: 2026-09-29。アプリの編集ビューは`NSTextView.usesFindBar = true`と`isIncrementalSearchingEnabled = true`を設定し、検索コマンドは`NSTextFinder.Action`を`performTextFinderAction`へ渡す。

Appleの[NSTextViewの検索メタデータ](https://developer.apple.com/documentation/appkit/find-panel-search-metadata)は、大文字小文字の区別と部分文字列の一致方法を標準検索UIが扱い、その情報を検索用ペーストボードの`findPanelSearchOptions`型に置くことを説明している。ローカルのmacOS SDKでも`findPanelCaseInsensitiveSearch`と`findPanelSubstringMatch`のキー、`fullWord`の一致種類を確認した。したがってS02について独自の検索ロジックや設定UIは追加せず、AppKitの条件選択と保持を利用する。

この確認はAPIとSDKに基づく。実機での標準検索バーの表示位置、条件の操作感、アプリ再起動後の保持範囲はV04の実機確認に残す。標準UIに不足が見つかった場合は、その条件に限って追加する。
