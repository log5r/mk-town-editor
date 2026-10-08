# キーボードショートカットの割り当て方針

## 既定値を変えたコマンド（#51）

| コマンド | 以前 | 現在 | 理由 |
| --- | --- | --- | --- |
| インラインコード | ⌘` | ⇧⌘C | ⌘`はmacOS全体の「次のウインドウへ移動」。キーウインドウのメニューが優先され、アプリ内でウインドウを切り替えられなくなっていた |
| 引用 | ⇧⌘>（`">"` + Shift） | ⌘>（`">"` のみ） | `">"` は配列ごとに必要な修飾キーで入力される文字。Shiftを重ねる指定は配列に依存する |
| タスクの完了切り替え | ⌥⌘T | ⇧⌘U | ⌥⌘Tは `ToolbarCommands` の「ツールバーを隠す」。⇧⌘Uは「メモ」アプリのチェック切り替えと同じ |

## 記号キーの指定

AppKitのメニューは、押されたキーで入力される文字（Shiftの効果を含む）とキー等価を比べる。US・ABC配列で⇧⌘.を押すと文字は `>` になるため、キー等価 `"."` に修飾キーとしてShiftを付けると一致しない。シフトで入力する記号は、その記号自体をキー等価にし、Shiftを付けない。`EditorShortcutsTests.testShiftedCharacterShortcutMatchesTheKeyThatTypesIt` で `NSMenu.performKeyEquivalent(with:)` を使って確認している。

## 予約リスト

`EditorShortcutRegistry.reserved` には、macOSの標準操作と、アプリのメニューに固定で割り当てたショートカットをすべて含める。ユーザーがパレットのコマンドに割り当てを上書きするとき、ここに含まれるキーは拒否する。

- コマンド自身の既定値は予約されていても許可する。⌘Fは「検索」コマンドの既定値で、プレビュー検索のメニューも同じキーを使う。
- `EditorShortcutsTests.testEveryFixedMenuShortcutIsReserved` は `Sources/MKTownEditor` の `.keyboardShortcut("x", modifiers: ...)` をすべて抽出し、予約リストに含まれることを確認する。メニューに固定のショートカットを追加したら、予約リストにも追加する。
