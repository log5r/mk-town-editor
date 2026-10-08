# キーボードショートカットの割り当て方針

## 既定値を変えたコマンド（#51）

| コマンド | 以前 | 現在 | 理由 |
| --- | --- | --- | --- |
| インラインコード | ⌘` | ⇧⌘C | ⌘`はmacOS全体の「次のウインドウへ移動」。キーウインドウのメニューが優先され、アプリ内でウインドウを切り替えられなくなっていた |
| 引用 | ⇧⌘>（`">"` + Shift） | ⌘>（`">"` のみ） | `">"` は配列ごとに必要な修飾キーで入力される文字。Shiftを重ねる指定は配列に依存する |
| タスクの完了切り替え | ⌥⌘T | ⇧⌘U | ⌥⌘Tは `ToolbarCommands` の「ツールバーを隠す」。⇧⌘Uは「メモ」アプリのチェック切り替えと同じ |

## 記号キーの指定

AppKitのメニューは、押されたキーで入力される文字（Shiftの効果を含む）とキー等価を比べる。US・ABC配列で⇧⌘.を押すと文字は `>` になるため、キー等価 `"."` に修飾キーとしてShiftを付けると一致しない。シフトで入力する記号は、その記号自体をキー等価にし、Shiftを付けない。`EditorShortcutsTests.testShiftedCharacterShortcutMatchesTheKeyThatTypesIt` で `NSMenu.performKeyEquivalent(with:)` を使って確認している。

## 記録したキーの保存形式（#52）

設定の「キーボード」タブはキー入力をそのまま記録する。`ShortcutChord(recordedKey:shifted:modifiers:)` は、修飾キーなしの文字とShiftだけを押した文字から次の形で保存する。

- 英字と数字はShiftを修飾キーとして残す（⇧⌘X、⇧⌘8）。既定値と同じ形式。
- 記号でShiftを押した場合は、Shiftで入力される記号自体をキーにし、Shiftを付けない（⇧⌘. → ⌘>）。上の「記号キーの指定」と同じ理由。
- Deleteは割り当ての解除、Escは中止、修飾キーなしのTabはフォーカス移動に使う。解除はキーが空の上書き（`ShortcutChord(key: "")`）として保存し、既定値に戻すまで既定のショートカットも使わない。

⌘付きのキーはメニューより先に `performKeyEquivalent(with:)` に届くため、記録中は⌘Qなども捕まえ、予約済みとして拒否する。

## 予約リスト

`EditorShortcutRegistry.reserved` には、macOSの標準操作と、アプリのメニューに固定で割り当てたショートカットをすべて含める。ユーザーがパレットのコマンドに割り当てを上書きするとき、ここに含まれるキーは拒否する。

- 新しい版で既定値を変えたキーを、利用者が既に別のコマンドへ割り当てている場合は、利用者の割り当てを優先し、そのコマンドの既定値を外す（`EditorShortcutRegistry.shortcut(for:overrides:)`）。
- コマンド自身の既定値は予約されていても許可する。⌘Fは「検索」コマンドの既定値で、プレビュー検索のメニューも同じキーを使う。
- `EditorShortcutsTests.testEveryFixedMenuShortcutIsReserved` は `Sources/MKTownEditor` の `.keyboardShortcut("x", modifiers: ...)` をすべて抽出し、予約リストに含まれることを確認する。メニューに固定のショートカットを追加したら、予約リストにも追加する。
