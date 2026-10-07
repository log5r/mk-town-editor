import AppKit
import Darwin
import CryptoKit
import Foundation

enum ExternalDiagramKind: String, CaseIterable, Sendable {
    case graphviz
    case plantuml

    init?(language: String?) {
        switch language?.lowercased() {
        case "dot", "graphviz": self = .graphviz
        case "plantuml", "puml": self = .plantuml
        default: return nil
        }
    }

    var title: String { self == .graphviz ? "Graphviz" : "PlantUML" }
    var sourceExtension: String { self == .graphviz ? "dot" : "puml" }
}

enum ExternalDiagramError: LocalizedError, Equatable {
    case notConfigured
    case invalidTool
    case sourceTooLarge
    case timedOut
    case cancelled
    case failed(String)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "描画器を設定で指定してください。")
        case .invalidTool: String(localized: "描画器のファイルを開けません。")
        case .sourceTooLarge: String(localized: "図の原文が大きすぎます。")
        case .timedOut: String(localized: "図の描画が時間内に完了しませんでした。")
        case .cancelled: String(localized: "図の描画を中止しました。")
        case let .failed(message): message
        case .invalidImage: String(localized: "描画結果の画像を読み取れません。")
        }
    }
}

struct ExternalDiagramConfiguration: Sendable {
    let graphvizExecutable: String
    let plantUMLJar: String

    func toolPath(for kind: ExternalDiagramKind) -> String {
        kind == .graphviz ? graphvizExecutable : plantUMLJar
    }
}

struct ExternalDiagramCommand: Equatable {
    let executable: String
    let arguments: [String]
    let securityProfile: String?

    static func make(kind: ExternalDiagramKind, toolPath: String,
                     input: URL, output: URL) -> ExternalDiagramCommand {
        if kind == .graphviz {
            return ExternalDiagramCommand(executable: toolPath,
                                          arguments: ["-Tpng", input.path, "-o", output.path],
                                          securityProfile: nil)
        }
        return ExternalDiagramCommand(executable: "/usr/bin/java",
                                      arguments: ["-DPLANTUML_SECURITY_PROFILE=SANDBOX", "-jar", toolPath,
                                                  "-failfast2", "-stdrpt", "-nometadata", "-tpng", "-pipe"],
                                      securityProfile: "SANDBOX")
    }
}

private final class DiagramProcessControl: @unchecked Sendable {
    let process = Process()
    let lock = NSLock()
    private(set) var cancelled = false
    private(set) var timedOut = false
    private var hasLaunched = false

    func didLaunch() {
        lock.lock(); hasLaunched = true; lock.unlock()
    }

    func stop(timeout: Bool) {
        lock.lock()
        let running = process.isRunning
        if hasLaunched && !running { lock.unlock(); return }
        if timeout { timedOut = true } else { cancelled = true }
        lock.unlock()
        if running { terminate() }
    }

    /// Sends SIGTERM, then SIGKILL if the tool is still running 250 ms later, so a tool
    /// that ignores SIGTERM cannot keep `waitUntilExit()` (and the diagram) waiting forever.
    private func terminate() {
        _ = Darwin.kill(process.processIdentifier, SIGTERM)
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    var stopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled || timedOut
    }

    var stopError: ExternalDiagramError? {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return .cancelled }
        if timedOut { return .timedOut }
        return nil
    }

    func signalIfStopped() {
        if stopped, process.isRunning { terminate() }
    }
}

private final class ExternalDiagramImageCache: @unchecked Sendable {
    let values = NSCache<NSString, NSData>()
    init() { values.totalCostLimit = 32_000_000 }
}

enum ExternalDiagramRenderer {
    private static let cache = ExternalDiagramImageCache()
    static func render(_ source: String, kind: ExternalDiagramKind,
                       configuration: ExternalDiagramConfiguration,
                       timeout: TimeInterval = 8,
                       readMetadata: WorkspaceFileMetadata.Reader = WorkspaceFileMetadata.read) async throws -> Data {
        try Task.checkCancellation()
        let tool = URL(fileURLWithPath: configuration.toolPath(for: kind))
        let metadata = try? readMetadata(tool)
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let generation = metadata?.generation?.map { String(format: "%02x", $0) }.joined() ?? ""
        let key = "\(kind.rawValue):\(tool.path):\(metadata?.modified?.timeIntervalSince1970 ?? 0):\(metadata?.size ?? 0):\(generation):\(digest)" as NSString
        if metadata?.identifiesContent == true, let cached = cache.values.object(forKey: key) { return cached as Data }
        let control = DiagramProcessControl()
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try renderBlocking(source, kind: kind, configuration: configuration,
                                   timeout: timeout, control: control)
            }.value
        } onCancel: {
            control.stop(timeout: false)
        }
        try Task.checkCancellation()
        // Without a generation identifier, size and date cannot identify the tool.
        // Bypass caching rather than reuse output from a replaced executable or JAR.
        if metadata?.identifiesContent == true {
            cache.values.setObject(result as NSData, forKey: key, cost: result.count)
        }
        return result
    }

    private static func renderBlocking(_ source: String, kind: ExternalDiagramKind,
                                       configuration: ExternalDiagramConfiguration,
                                       timeout: TimeInterval, control: DiagramProcessControl) throws -> Data {
        guard source.utf8.count <= 256_000 else { throw ExternalDiagramError.sourceTooLarge }
        let toolPath = configuration.toolPath(for: kind)
        guard !toolPath.isEmpty else { throw ExternalDiagramError.notConfigured }
        let manager = FileManager.default
        guard toolPath.hasPrefix("/"), manager.fileExists(atPath: toolPath),
              kind == .plantuml || manager.isExecutableFile(atPath: toolPath) else {
            throw ExternalDiagramError.invalidTool
        }
        let directory = manager.temporaryDirectory.appendingPathComponent("mktown-diagram-\(UUID().uuidString)",
                                                                    isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let input = directory.appendingPathComponent("diagram.\(kind.sourceExtension)")
        let output = directory.appendingPathComponent("diagram.png")
        let errors = directory.appendingPathComponent("stderr.txt")
        try Data(source.utf8).write(to: input)
        _ = manager.createFile(atPath: errors.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errors)
        defer { try? errorHandle.close() }
        let process = control.process
        process.currentDirectoryURL = directory
        process.standardError = errorHandle
        let command = ExternalDiagramCommand.make(kind: kind, toolPath: toolPath,
                                                  input: input, output: output)
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        var inputHandle: FileHandle?
        var outputHandle: FileHandle?
        defer { try? inputHandle?.close(); try? outputHandle?.close() }
        if kind == .plantuml {
            _ = manager.createFile(atPath: output.path, contents: nil)
            inputHandle = try FileHandle(forReadingFrom: input)
            outputHandle = try FileHandle(forWritingTo: output)
            process.standardInput = inputHandle
            process.standardOutput = outputHandle
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        if let profile = command.securityProfile {
            process.environment = ProcessInfo.processInfo.environment.merging(
                ["PLANTUML_SECURITY_PROFILE": profile]) { _, new in new }
        }
        if let error = control.stopError { throw error }
        try process.run()
        control.didLaunch()
        control.signalIfStopped()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + max(0.1, timeout))
        timer.setEventHandler { control.stop(timeout: true) }
        timer.resume()
        process.waitUntilExit()
        timer.cancel()
        if let error = control.stopError { throw error }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: errors, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ExternalDiagramError.failed(String(detail.prefix(1200)).isEmpty
                ? String(localized: "図の描画に失敗しました。") : String(detail.prefix(1200)))
        }
        guard let attributes = try? manager.attributesOfItem(atPath: output.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 10_000_000,
              let data = try? Data(contentsOf: output),
              NSBitmapImageRep(data: data) != nil else { throw ExternalDiagramError.invalidImage }
        return data
    }
}
