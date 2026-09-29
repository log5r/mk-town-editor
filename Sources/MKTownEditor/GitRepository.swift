import Foundation

struct GitRevision: Equatable, Sendable, Identifiable {
    let hash: String
    let shortHash: String
    let subject: String
    var id: String { hash }
}

struct GitSnapshot: Sendable {
    let rootURL: URL
    let fileURL: URL
    let relativePath: String
    let status: String
    let diff: String
    let history: [GitRevision]
}

enum GitRepositoryError: LocalizedError {
    case invalidDocument
    case commandFailed(String)
    case timedOut
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidDocument: String(localized: "Git管理下の保存済み文書を選んでください。")
        case let .commandFailed(message): message
        case .timedOut: String(localized: "Gitの読み取りが時間切れになりました。")
        case .tooLarge: String(localized: "Gitの読み取り結果が大きすぎます。")
        }
    }
}

enum GitRepository {
    static func load(for documentURL: URL) throws -> GitSnapshot {
        guard documentURL.isFileURL else { throw GitRepositoryError.invalidDocument }
        let fileURL = documentURL.standardizedFileURL
        let folder = fileURL.deletingLastPathComponent()
        let rootPath = try run(in: folder, arguments: ["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootPath.isEmpty else { throw GitRepositoryError.invalidDocument }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        guard fileURL.path.hasPrefix(root.path + "/") else { throw GitRepositoryError.invalidDocument }
        let relativePath = String(fileURL.path.dropFirst(root.path.count + 1))
        let status = try run(in: root, arguments: ["status", "--short", "--untracked-files=normal"])
        let hasHead = (try? run(in: root, arguments: ["rev-parse", "--verify", "HEAD"])) != nil
        let diff = hasHead ? try run(in: root,
            arguments: ["diff", "--no-ext-diff", "HEAD", "--", relativePath]) : ""
        let historyText = hasHead ? try run(in: root, arguments: [
            "log", "-n", "40", "--format=%H%x1f%h%x1f%s", "--", relativePath
        ]) : ""
        let history = historyText.split(separator: "\n").compactMap { line -> GitRevision? in
            let parts = line.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return GitRevision(hash: String(parts[0]), shortHash: String(parts[1]),
                               subject: String(parts[2]))
        }
        return GitSnapshot(rootURL: root, fileURL: fileURL, relativePath: relativePath,
                           status: status, diff: diff, history: history)
    }

    static func content(of revision: GitRevision, in snapshot: GitSnapshot) throws -> String {
        guard revision.hash.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil,
              snapshot.history.contains(revision) else { throw GitRepositoryError.invalidDocument }
        return try run(in: snapshot.rootURL,
                       arguments: ["show", "--no-ext-diff", "\(revision.hash):\(snapshot.relativePath)"])
    }

    private static func run(in folder: URL, arguments: [String]) throws -> String {
        let temporary = FileManager.default.temporaryDirectory
        let outputURL = temporary.appendingPathComponent("mktown-git-\(UUID().uuidString).out")
        let errorURL = temporary.appendingPathComponent("mktown-git-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path, "-c", "core.pager=cat", "-c", "core.quotepath=false"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }
        process.standardOutput = output
        process.standardError = errors
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            throw GitRepositoryError.timedOut
        }
        try output.synchronize()
        try errors.synchronize()
        let data = try Data(contentsOf: outputURL)
        let errorData = try Data(contentsOf: errorURL)
        guard data.count <= 4_000_000, errorData.count <= 20_000 else {
            throw GitRepositoryError.tooLarge
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitRepositoryError.commandFailed(message.isEmpty
                ? String(localized: "Gitの読み取りに失敗しました。") : message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
