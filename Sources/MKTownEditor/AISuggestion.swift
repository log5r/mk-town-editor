import Foundation
import Security

/// Sends only the explicitly selected text to the fixed OpenAI Responses API endpoint.
enum AISuggestion {
    enum Operation: String, CaseIterable, Identifiable {
        case proofread, translate
        var id: String { rawValue }
        var title: String {
            self == .proofread ? String(localized: "推敲") : String(localized: "翻訳")
        }
    }

    enum SuggestionError: LocalizedError {
        case emptySelection, tooLong, missingKey, invalidLanguage, invalidResponse
        case httpStatus(Int)
        case redirect

        var errorDescription: String? {
            switch self {
            case .emptySelection: String(localized: "編集画面で対象の文字列を選択してください。")
            case .tooLong: String(localized: "一度に送れる選択範囲は6,000文字までです。")
            case .missingKey: String(localized: "OpenAI APIキーを入力してください。")
            case .invalidLanguage: String(localized: "翻訳先の言語を入力してください。")
            case .invalidResponse: String(localized: "提案の本文を応答から読み取れません。")
            case .httpStatus(let code): String(localized: "OpenAI APIがHTTP \(code)を返しました。")
            case .redirect: String(localized: "APIの転送先が変わったため送信を停止しました。")
            }
        }
    }

    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    static let model = "gpt-6-luna"

    static func request(selectedText: String, operation: Operation,
                        targetLanguage: String, apiKey: String) throws -> URLRequest {
        guard !selectedText.isEmpty else { throw SuggestionError.emptySelection }
        guard selectedText.count <= 6_000 else { throw SuggestionError.tooLong }
        guard !apiKey.isEmpty, !apiKey.contains(where: \.isWhitespace) else {
            throw SuggestionError.missingKey
        }
        let instructions: String
        switch operation {
        case .proofread:
            instructions = "Proofread the supplied text. Preserve its language, meaning, Markdown syntax, and line breaks where possible. Return only the revised text, without commentary, quotes, or code fences."
        case .translate:
            let target = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, target.count <= 60,
                  !target.contains("\n"), !target.contains("\r") else {
                throw SuggestionError.invalidLanguage
            }
            instructions = "Translate the supplied text into \(target). Preserve Markdown syntax and line breaks where possible. Return only the translated text, without commentary, quotes, or code fences."
        }
        let payload = RequestBody(model: model, instructions: instructions,
                                  input: selectedText, store: false,
                                  reasoning: Reasoning(effort: "none"), max_output_tokens: 8192)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    static func responseText(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard response.status == "completed" else { throw SuggestionError.invalidResponse }
        let text = response.output.flatMap { $0.content ?? [] }
            .filter { $0.type == "output_text" }
            .compactMap(\.text).joined()
        guard !text.isEmpty, text.count <= 20_000 else { throw SuggestionError.invalidResponse }
        return text
    }

    private struct RequestBody: Encodable {
        let model: String
        let instructions: String
        let input: String
        let store: Bool
        let reasoning: Reasoning
        let max_output_tokens: Int
    }

    private struct Reasoning: Encodable { let effort: String }

    private struct ResponseBody: Decodable {
        let status: String
        let output: [Output]
        struct Output: Decodable {
            let content: [Content]?
        }
        struct Content: Decodable {
            let type: String
            let text: String?
        }
    }
}

private final class AIRequestNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum AISuggestionTransport {
    static func suggest(_ request: URLRequest) async throws -> String {
        let session = URLSession(configuration: .ephemeral, delegate: AIRequestNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AISuggestion.SuggestionError.invalidResponse }
        if (300..<400).contains(http.statusCode) { throw AISuggestion.SuggestionError.redirect }
        guard (200..<300).contains(http.statusCode) else {
            throw AISuggestion.SuggestionError.httpStatus(http.statusCode)
        }
        return try AISuggestion.responseText(from: data)
    }
}

enum AICredentialStore {
    private static let service = "jp.mktowneditor.ai.openai"
    private static let account = "responses-api"

    static func save(_ key: String) throws {
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            throw AISuggestion.SuggestionError.missingKey
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let data = Data(key.utf8)
        let status = SecItemAdd(query.merging([kSecValueData as String: data]) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(update))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func load() throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return key
    }
}

struct AISuggestionRevision {
    let source: String
    let range: NSRange
    let selectedText: String

    init?(source: String, range: NSRange) {
        guard range.location >= 0, range.length > 0,
              NSMaxRange(range) <= (source as NSString).length else { return nil }
        self.source = source
        self.range = range
        selectedText = (source as NSString).substring(with: range)
    }

    func edit(suggested: String, currentSource: String) -> MarkdownEdit? {
        guard currentSource == source, !suggested.isEmpty,
              suggested != selectedText else { return nil }
        return MarkdownEdit(range: range, replacement: suggested,
            selection: NSRange(location: range.location + (suggested as NSString).length,
                               length: 0))
    }
}

struct AISuggestionDiff {
    enum Kind { case unchanged, removed, added }
    struct Row { let kind: Kind; let text: String }

    static func rows(original: String, suggested: String) -> [Row] {
        let old = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let new = suggested.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let difference = new.difference(from: old)
        let removed = Set(difference.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }
            return nil
        })
        let added = Set(difference.insertions.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }
            return nil
        })
        var oldIndex = 0
        var newIndex = 0
        var result: [Row] = []
        while oldIndex < old.count || newIndex < new.count {
            if removed.contains(oldIndex), oldIndex < old.count {
                result.append(Row(kind: .removed, text: old[oldIndex]))
                oldIndex += 1
            } else if added.contains(newIndex), newIndex < new.count {
                result.append(Row(kind: .added, text: new[newIndex]))
                newIndex += 1
            } else if oldIndex < old.count, newIndex < new.count {
                result.append(Row(kind: .unchanged, text: new[newIndex]))
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < old.count {
                result.append(Row(kind: .removed, text: old[oldIndex]))
                oldIndex += 1
            } else if newIndex < new.count {
                result.append(Row(kind: .added, text: new[newIndex]))
                newIndex += 1
            }
        }
        return result
    }
}
