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

struct GitStatusEntry: Equatable, Sendable, Identifiable {
    let path: String
    let indexStatus: Character
    let worktreeStatus: Character
    var id: String { path }
    var isConflicted: Bool {
        indexStatus == "U" || worktreeStatus == "U" ||
            (indexStatus == "A" && worktreeStatus == "A") ||
            (indexStatus == "D" && worktreeStatus == "D")
    }
    var isStaged: Bool { indexStatus != " " && indexStatus != "?" && !isConflicted }
}

enum GitRepositoryError: LocalizedError {
    case invalidDocument
    case commandFailed(String)
    case timedOut
    case commitTimedOut
    case tooLarge
    case invalidSelection
    case unresolvedConflict

    var errorDescription: String? {
        switch self {
        case .invalidDocument: String(localized: "Git管理下の保存済み文書を選んでください。")
        case let .commandFailed(message): message
        case .timedOut: String(localized: "Gitの読み取りが時間切れになりました。")
        case .commitTimedOut: String(localized: "コミットが時間切れになりました。リポジトリのフックが終了しなかった可能性があります。")
        case .tooLarge: String(localized: "Gitの読み取り結果が大きすぎます。")
        case .invalidSelection: String(localized: "変更ファイルの選択を確認してください。")
        case .unresolvedConflict: String(localized: "競合記号を解消し、保存してからステージしてください。")
        }
    }
}

enum GitRepository {
    static func load(for documentURL: URL) throws -> GitSnapshot {
        guard documentURL.isFileURL else { throw GitRepositoryError.invalidDocument }
        let fileURL = documentURL.standardizedFileURL
        let folder = fileURL.deletingLastPathComponent()
        // Git reports the top level with symbolic links resolved, so the document's place in
        // the repository comes from Git's own prefix instead of comparing the two paths.
        let location = try run(in: folder, arguments: ["rev-parse", "--show-toplevel", "--show-prefix"])
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard location.count >= 2, !location[0].isEmpty, !fileURL.lastPathComponent.isEmpty
        else { throw GitRepositoryError.invalidDocument }
        let root = URL(fileURLWithPath: location[0], isDirectory: true).standardizedFileURL
        let relativePath = location[1] + fileURL.lastPathComponent
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

    static func statusEntries(in root: URL) throws -> [GitStatusEntry] {
        let output = try run(in: root,
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=normal"])
        return parseStatus(output)
    }

    static func parseStatus(_ output: String) -> [GitStatusEntry] {
        let records = output.split(separator: "\0", omittingEmptySubsequences: true)
        var entries: [GitStatusEntry] = []
        var index = 0
        while index < records.count {
            let record = String(records[index])
            guard record.utf8.count >= 4 else { index += 1; continue }
            let flags = Array(record.prefix(2))
            let path = String(record.dropFirst(3))
            entries.append(GitStatusEntry(path: path, indexStatus: flags[0], worktreeStatus: flags[1]))
            index += 1
            if flags.contains("R") || flags.contains("C") { index += 1 }
        }
        return entries
    }

    static func diff(for path: String, in root: URL, staged: Bool) throws -> String {
        try validate([path], in: root)
        let arguments = staged
            ? ["diff", "--cached", "--no-ext-diff", "--", path]
            : ["diff", "--no-ext-diff", "--", path]
        return try run(in: root, arguments: arguments)
    }

    static func stage(_ paths: [String], in root: URL) throws {
        try validate(paths, in: root)
        let conflicts = Set(try statusEntries(in: root).filter(\.isConflicted).map(\.path))
        guard paths.allSatisfy({ !conflicts.contains($0) }) else {
            throw GitRepositoryError.unresolvedConflict
        }
        _ = try run(in: root, arguments: ["add", "--"] + paths)
    }

    static func unstage(_ paths: [String], in root: URL) throws {
        try validate(paths, in: root)
        let hasHead = (try? run(in: root, arguments: ["rev-parse", "--verify", "HEAD"])) != nil
        let arguments = hasHead ? ["reset", "-q", "HEAD", "--"] + paths
            : ["rm", "--cached", "--"] + paths
        _ = try run(in: root, arguments: arguments)
    }

    static func stageResolvedConflict(_ path: String, in root: URL) throws {
        try validate([path], in: root)
        guard try statusEntries(in: root).contains(where: {
            $0.path == path && $0.isConflicted
        }) else { throw GitRepositoryError.invalidSelection }
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard let data = try? Data(contentsOf: url),
              let source = String(data: data, encoding: .utf8),
              !source.components(separatedBy: .newlines).contains(where: {
                  $0.hasPrefix("<<<<<<< ") || $0.hasPrefix("=======") || $0.hasPrefix(">>>>>>> ")
              }) else { throw GitRepositoryError.unresolvedConflict }
        _ = try run(in: root, arguments: ["add", "--", path])
    }

    static func commit(message: String, in root: URL) throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = try statusEntries(in: root)
        guard !trimmed.isEmpty, trimmed.count <= 2_000,
              entries.contains(where: \.isStaged),
              !entries.contains(where: \.isConflicted) else {
            throw GitRepositoryError.invalidSelection
        }
        // Hooks run as they do from the command line; a rejecting hook's message is shown as the error.
        do {
            _ = try run(in: root, arguments: ["commit", "-m", trimmed], timeout: commitTimeout)
        } catch GitRepositoryError.timedOut {
            throw GitRepositoryError.commitTimedOut
        }
    }

    /// Hooks such as linters can take far longer than a read.
    static let commitTimeout: TimeInterval = 120

    private static func validate(_ paths: [String], in root: URL) throws {
        guard !paths.isEmpty else { throw GitRepositoryError.invalidSelection }
        let available = Set(try statusEntries(in: root).map(\.path))
        guard paths.allSatisfy({ available.contains($0) && !$0.isEmpty &&
            !$0.hasPrefix("/") && !$0.components(separatedBy: "/").contains("..") }) else {
            throw GitRepositoryError.invalidSelection
        }
    }

    private static func run(in folder: URL, arguments: [String], timeout: TimeInterval = 8) throws -> String {
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
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw GitRepositoryError.timedOut
        }
        try output.synchronize()
        try errors.synchronize()
        let data = try Data(contentsOf: outputURL)
        // Hooks and progress can write a lot to standard error; the end holds the failure.
        let errorData = try Data(contentsOf: errorURL).suffix(20_000)
        guard data.count <= 4_000_000 else { throw GitRepositoryError.tooLarge }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitRepositoryError.commandFailed(message.isEmpty
                ? String(localized: "Gitの読み取りに失敗しました。") : message)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
