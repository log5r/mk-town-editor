import SwiftUI
import UniformTypeIdentifiers

struct MarkdownDocument: FileDocument {
    #if SWIFT_PACKAGE
    // A SwiftPM executable has no application Info.plist declaring imported types.
    static let markdownType = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
    #else
    static let markdownType = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    #endif
    static let readableContentTypes: [UTType] = [markdownType, .plainText]
    static let writableContentTypes: [UTType] = [markdownType]

    var text: String
    var format = MarkdownTextFormat()

    init(text: String = WorkspaceDocumentTemplate.starter.text) {
        self.text = text
    }

    init(data: Data) throws {
        let result = try MarkdownTextFormat.read(data)
        text = result.text
        format = result.format
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self = try Self(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: encodedData())
    }

    func encodedData() -> Data {
        format.encode(text)
    }

    static func decode(_ data: Data) throws -> String {
        try MarkdownTextFormat.read(data).text
    }
}
