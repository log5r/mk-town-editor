# Tree-sitterの導入

[コードブロックの色分け](code-syntax-highlighting.md)のうち、JavaScript・TypeScript・TSX・RubyをTree-sitterで解析するための依存、設定、運用の記録。比較の根拠は[コード色分けの設計評価](code-syntax-highlighting-design.md)と[コード色分けエンジンの比較記録](code-syntax-engine-comparison.md)にある（Issue #67）。

## 依存と版

| パッケージ | 版 | ライセンス | 用途 |
| --- | --- | --- | --- |
| swift-tree-sitter | 0.25.0 | BSD 3-Clause（Copyright (c) 2021 Chime） | Swiftからの呼び出し（`Parser`、`Query`、`QueryCursor`） |
| tree-sitter | 0.25.10 | MIT | ランタイム（swift-tree-sitterが依存する） |
| tree-sitter-javascript | 0.23.1（`exact`） | MIT | JavaScript |
| tree-sitter-typescript | 0.23.2 | MIT | TypeScriptとTSX（`TreeSitterTypeScript`・`TreeSitterTSX`の2モジュール） |
| tree-sitter-ruby | 0.23.1 | MIT | Ruby |

版の正本は `Package.resolved` である。`TreeSitterGrammar.packageVersion` はこれと一致させ、`testPackageVersionsMatchPackageResolved` が確かめる。

## ライセンス

swift-tree-sitterのBSD 3-Clauseは、再配布時に著作権表示と条件の掲載を求める。全文は[サードパーティのライセンス](third-party-licenses.md)に転載し、READMEのライセンス節から案内している。アプリ内に謝辞の画面やファイルはない（SwiftMathのライセンスもアプリ内には掲載していない）。MITの4つも同じファイルに載せている。

## 対応OSとツールチェーン

macOS 14とswift-tools-version 6.0は変えない。swift-tree-sitterはmacOS 10.13以降に対応し、文法パッケージはプラットフォームを宣言していないため、この組み合わせで追加の設定は要らない。

## tree-sitter-javascript 0.25.0を使わない理由

0.25.0の `Package.swift` は、`FileManager.default.fileExists(atPath: "src/scanner.c")` を現在のディレクトリからの相対パスで調べる。依存として取り込まれると、現在のディレクトリは利用側のものなので `scanner.c` が見つからず、ビルド対象から外れる。結果として `_tree_sitter_javascript_external_scanner_*` のリンクエラーになる。0.23.1に `exact` で固定して避けている。上げるときは、まず依存として取り込んだリンクが通ることを確かめる。

## SwiftPMとXcodeの設定

- SwiftPM：`Package.swift` の `dependencies` と、実行ターゲットの `dependencies` に製品を加える。
- Xcode：`MKTownEditor.xcodeproj/project.pbxproj` に、パッケージごとに次の6か所を設ける。`PBXBuildFile`（Frameworks）、ターゲットの `PBXFrameworksBuildPhase`、ターゲットの `packageProductDependencies`、プロジェクトの `packageReferences`、`XCRemoteSwiftPackageReference`、`XCSwiftPackageProductDependency`。
- `Sources` に新しいファイルを足したら、`project.pbxproj` にも登録する（`TreeSitterSyntaxParser.swift` と `CodeSyntaxAnalyzer.swift` は登録済み）。テストファイルは登録しない。
- 文法パッケージは `queries` を含むリソースバンドルを作り、SwiftPMとXcodeの両方、`Tools/make-app-bundle.sh` がアプリへコピーする。クエリは自前のものをSwiftに埋め込んでいて、このバンドルは読まない。合計76 KBなので、そのままにしている。

## 文法を更新する手順

1. `Package.swift` と `Package.resolved` を更新する。
2. `TreeSitterGrammar.packageVersion` を新しい版に合わせる。
3. `swift test --filter 'TreeSitter|CodeSyntax'` を実行する。`Package.resolved` との一致も確かめられる。
4. 文法の変更でノード名が変わる場合は、クエリを直し、`queryRevision` を上げる。クエリだけを変えたときも上げる。
5. 比較記録の事例を再確認する。

キャッシュの鍵に文法の版とクエリの版が入っているため、上げ忘れると古い結果が使われる。

## 設計上の判断

- クエリを埋め込む理由：文法パッケージ付属のクエリは述語（`#match?` など）を使い、字句の種類の名前もこのアプリと合わない。自前のクエリを `TreeSitterSyntaxParser.swift` に持てば、字句の種類との対応と版（`queryRevision`）をコードで管理できる。
- 述語を使わない理由：`QueryCursor` は述語を評価しない。述語を書いても条件が効かず、全件に一致する。
- 呼び出しごとに `Parser` を作る：`Parser` は同時に使えない。共有すると排他が要り、`DocumentSnapshot` の並行生成の妨げになる。
- 長さの上限（100万UTF-16単位）とタイムアウト（0.5秒）：巨大な本文や文法の病的な入力で、解析が終わらないのを防ぐ。超えたブロックは単色にする。
- タイムアウトの実装：`Parser.timeout` はSwiftTreeSitterが `ts_parser_set_timeout_micros` で実装している。tree-sitter 0.25 はこの関数を非推奨とし、進捗コールバック付きの解析オプションを勧めている。swift-tree-sitter の版を上げるときは、タイムアウトが効くかを確かめる（長さの上限が恒久的な防御である）。
- 構文木は解析のたびに解放する。保持するのは `CodeSyntaxTokenRange` だけである。

## 言語を足す手順

1. 文法パッケージを `Package.swift`、`Package.resolved`、`project.pbxproj` に加える。
2. `TreeSitterGrammar` に `case` を足し、`Language`、`packageVersion`、クエリを定義する。
3. `CodeSyntaxLanguages` の正規名と別名を、走査器の定義から取り除いてTree-sitterへ移す。
4. `testPackageVersionsMatchPackageResolved` の対応表に加える。
5. 比較記録に、旧走査器との差を事例で追記する。
6. [コードブロックの色分け](code-syntax-highlighting.md)の対応言語を更新する。

## 確認コマンド

```sh
swift test --filter 'TreeSitter|CodeSyntax'
xcodebuild build -project MKTownEditor.xcodeproj -scheme MKTownEditor -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
python3 -B -m unittest discover -s Tools -p 'test_*.py'
MKTOWN_PERF=1 swift test -c release --filter CodeSyntaxPerformanceTests 2>&1 | grep PERF
```
