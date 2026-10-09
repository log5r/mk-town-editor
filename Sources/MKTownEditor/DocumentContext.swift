import Foundation

/// Location-dependent services for one document. The document contents remain in FileDocument.
struct DocumentContext: Equatable, Sendable {
    let fileURL: URL?
    var attachmentDirectory: AttachmentDirectory = .assets
    var markdownDialect: MarkdownDialect = .extended
    var crossReferences: MarkdownCrossReferences? = nil
    /// 解決済みの参考文献。`nil` の場合は描画時に書類のフォルダから読み込む。
    var citationCatalog: MarkdownCitationCatalog? = nil
    /// 解析済みのコードブロックの字句（鍵は `MarkdownBlock.id`）。描画する解析結果自身から求めたものだけを入れる。
    /// 字句はブロックの本文だけで決まる派生値なので、同値判定には含めない（含めると版が変わるたびに描画キャッシュが全て無効になる）。
    var codeSyntaxTokens: [Int: [CodeSyntaxTokenRange]]? = nil

    static func == (lhs: DocumentContext, rhs: DocumentContext) -> Bool {
        lhs.fileURL == rhs.fileURL && lhs.attachmentDirectory == rhs.attachmentDirectory &&
            lhs.markdownDialect == rhs.markdownDialect && lhs.crossReferences == rhs.crossReferences &&
            lhs.citationCatalog == rhs.citationCatalog
    }

    var directoryURL: URL? {
        guard let fileURL, fileURL.isFileURL else { return nil }
        return fileURL.deletingLastPathComponent().standardizedFileURL
    }

    func resolveLocalResource(_ relativePath: String) -> URL? {
        guard let directoryURL, !relativePath.isEmpty else { return nil }
        let path = relativePath.removingPercentEncoding ?? relativePath
        guard !path.hasPrefix("/"), URL(string: path)?.scheme == nil else { return nil }
        return URL(fileURLWithPath: path, relativeTo: directoryURL).standardizedFileURL
    }
}
