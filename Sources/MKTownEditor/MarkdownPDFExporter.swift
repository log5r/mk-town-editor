import AppKit
import Foundation

enum MarkdownPDFExportError: LocalizedError {
    case printingFailed
    case emptyOutput
    case invalidMargins

    var errorDescription: String? {
        switch self {
        case .printingFailed: String(localized: "PDFの作成に失敗しました。")
        case .emptyOutput: String(localized: "作成したPDFを読み取れません。")
        case .invalidMargins: String(localized: "余白が用紙サイズに対して大きすぎます。")
        }
    }
}

struct MarkdownPrintSettings {
    var topMargin: Double = 48
    var bottomMargin: Double = 48
    var leftMargin: Double = 48
    var rightMargin: Double = 48
    var header = false
    var footer = false

    func isValid(for paperSize: NSSize) -> Bool {
        [topMargin, bottomMargin, leftMargin, rightMargin].allSatisfy { $0.isFinite && $0 >= 0 }
            && paperSize.width - leftMargin - rightMargin >= 100
            && paperSize.height - topMargin - bottomMargin >= 100
    }

    func apply(to info: NSPrintInfo) throws {
        guard isValid(for: info.paperSize) else { throw MarkdownPDFExportError.invalidMargins }
        info.topMargin = topMargin
        info.bottomMargin = bottomMargin
        info.leftMargin = leftMargin
        info.rightMargin = rightMargin
        info.dictionary()[NSPrintInfo.AttributeKey(rawValue: "NSPrintHeaderAndFooter")] = header || footer
    }
}

@MainActor
enum MarkdownPDFExporter {
    static func printInfo(destination: URL, preset: MarkdownExportPreset = .standard) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.leftMargin = CGFloat(preset.margin)
        info.rightMargin = CGFloat(preset.margin)
        info.topMargin = CGFloat(preset.margin)
        info.bottomMargin = CGFloat(preset.margin)
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        return info
    }

    static func export(_ markdown: String, documentURL: URL?, to destination: URL,
                       preset: MarkdownExportPreset = .standard,
                       dialect: MarkdownDialect = .extended) throws {
        let info = printInfo(destination: destination, preset: preset)
        let textView = try printableView(markdown, documentURL: documentURL, printInfo: info,
                                         preset: preset, dialect: dialect)
        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw MarkdownPDFExportError.printingFailed }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
            throw MarkdownPDFExportError.emptyOutput
        }
    }

    static func printableView(_ markdown: String, documentURL: URL?, printInfo info: NSPrintInfo,
                              title: String = "", header: Bool = false, footer: Bool = false,
                              preset: MarkdownExportPreset = .standard,
                              dialect: MarkdownDialect = .extended) throws -> NSTextView {
        let preferredWidth = CGFloat(preset.bodyWidth) * 0.75
        let width = min(info.paperSize.width - info.leftMargin - info.rightMargin, preferredWidth)
        let height = info.paperSize.height - info.topMargin - info.bottomMargin
        guard width >= 100, height >= 100 else { throw MarkdownPDFExportError.invalidMargins }
        let html = MarkdownHTMLExporter.render(markdown, documentURL: documentURL,
                                               preset: preset, printLayout: true, dialect: dialect)
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        let attributed = NSMutableAttributedString(attributedString: try NSAttributedString(
            data: Data(html.utf8), options: options, documentAttributes: nil
        ))
        return makeView(attributed, width: width, height: height, preferredWidth: preferredWidth,
                        title: title, header: header, footer: footer)
    }

    static func printableViewAsync(_ markdown: String, documentURL: URL?, printInfo info: NSPrintInfo,
                                   title: String = "", header: Bool = false, footer: Bool = false,
                                   preset: MarkdownExportPreset = .standard,
                                   dialect: MarkdownDialect = .extended) async throws -> NSTextView {
        let preferredWidth = CGFloat(preset.bodyWidth) * 0.75
        let width = min(info.paperSize.width - info.leftMargin - info.rightMargin, preferredWidth)
        let height = info.paperSize.height - info.topMargin - info.bottomMargin
        guard width >= 100, height >= 100 else { throw MarkdownPDFExportError.invalidMargins }
        let html = try await MarkdownHTMLExporter.renderAsync(markdown, documentURL: documentURL,
            preset: preset, printLayout: true, dialect: dialect)
        let attributed = NSMutableAttributedString(attributedString: try await DocumentWork.loadHTML(html))
        try Task.checkCancellation()
        let view = makeView(attributed, width: width, height: height, preferredWidth: preferredWidth,
                        title: title, header: header, footer: footer, layoutImmediately: false)
        if let manager = view.layoutManager, let storage = view.textStorage, let container = view.textContainer {
            for start in stride(from: 0, to: storage.length, by: 5_000) {
                try Task.checkCancellation()
                manager.ensureLayout(forCharacterRange: NSRange(location: start, length: min(5_000, storage.length - start)))
                await Task.yield()
            }
            view.frame.size.height = max(100, ceil(manager.usedRect(for: container).height))
        }
        try Task.checkCancellation()
        return view
    }

    static func exportAsync(_ markdown: String, documentURL: URL?, to destination: URL,
                            preset: MarkdownExportPreset = .standard,
                            dialect: MarkdownDialect = .extended) async throws {
        // Cancellation before publication preserves the destination; once the atomic
        // write starts, a completed publication is reported as success.
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".mktown-pdf-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let info = printInfo(destination: temporary, preset: preset)
        let view = try await printableViewAsync(markdown, documentURL: documentURL, printInfo: info,
                                                preset: preset, dialect: dialect)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        guard try await run(operation) else { throw MarkdownPDFExportError.printingFailed }
        try Task.checkCancellation()
        let data = try await DocumentWork.perform {
            let data = try Data(contentsOf: temporary)
            guard !data.isEmpty else { throw MarkdownPDFExportError.emptyOutput }
            return data
        }
        try await DocumentWork.commit { try data.write(to: destination, options: .atomic) }
    }

    static func run(_ operation: NSPrintOperation) async throws -> Bool {
        if Task.isCancelled {
            if NSPrintOperation.current === operation { NSPrintOperation.current = nil }
            throw CancellationError()
        }
        let cancellation = PrintCancellation()
        let completion = PrintCompletion()
        let view = operation.view as? PDFTextView
        view?.printCancellation = cancellation
        defer { view?.printCancellation = nil }
        let window = NSApp.keyWindow ?? NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        // AppKit calls NSTextView on the main actor. A thread-safe signal lets
        // rendering callbacks observe cancellation even before the actor yields.
        operation.canSpawnSeparateThread = false
        operation.showsProgressPanel = true
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.continuation = continuation
                if cancellation.isCancelled {
                    completion.continuation = nil
                    if NSPrintOperation.current === operation { NSPrintOperation.current = nil }
                    continuation.resume(returning: false)
                    return
                }
                operation.runModal(for: window, delegate: completion,
                    didRun: #selector(PrintCompletion.didRun(_:success:context:)), contextInfo: nil)
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in completion.cancel(operation, window: window) }
        }
        // Wait for AppKit's completion before releasing its delegate or removing
        // the temporary output, and before another print operation can start.
        withExtendedLifetime(completion) {}
        try Task.checkCancellation()
        if operation.printInfo.jobDisposition == .cancel { throw CancellationError() }
        return result
    }

    private static func makeView(_ attributed: NSMutableAttributedString, width: CGFloat, height: CGFloat,
                                 preferredWidth: CGFloat, title: String, header: Bool, footer: Bool,
                                 layoutImmediately: Bool = true) -> NSTextView {
        let textView = PDFTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.printableHeight = height
        textView.preferredWidth = preferredWidth
        textView.headerTitle = title
        textView.showsHeader = header
        textView.showsFooter = footer
        let markerRange = (attributed.string as NSString).range(of: MarkdownHTMLExporter.coverBreakMarker)
        if markerRange.location != NSNotFound {
            attributed.deleteCharacters(in: markerRange)
            textView.coverBreakCharacter = markerRange.location
        }
        textView.isRichText = true
        textView.isEditable = false
        textView.textContainerInset = .zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attributed)
        if layoutImmediately, let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            textView.frame.size.height = max(100, ceil(layoutManager.usedRect(for: container).height))
        }
        return textView
    }
}

class PDFTextView: NSTextView {
    var printCancellation: PrintCancellation?
    var printableHeight: CGFloat = 740
    var preferredWidth: CGFloat = 600
    var headerTitle = ""
    var showsHeader = false
    var showsFooter = false
    var coverBreakCharacter: Int?
    private var pageRects: [NSRect] = []

    override var pageHeader: NSAttributedString {
        NSAttributedString(string: showsHeader ? headerTitle : "")
    }

    override var pageFooter: NSAttributedString {
        guard showsFooter, let operation = NSPrintOperation.current else {
            return NSAttributedString(string: "")
        }
        return NSAttributedString(string: "\(operation.currentPage) / \(operation.pageRange.length)")
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        guard !abortCancelledPrint() else { return cancelledPageRange(range) }
        guard let layoutManager, let textStorage else { return false }
        if let info = NSPrintOperation.current?.printInfo {
            let width = max(100, min(info.paperSize.width - info.leftMargin - info.rightMargin,
                                     preferredWidth))
            printableHeight = max(100, info.paperSize.height - info.topMargin - info.bottomMargin)
            if abs(bounds.width - width) > 0.5 {
                frame.size.width = width
                textContainer?.containerSize.width = width
                layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0,
                                                                           length: textStorage.length),
                                               actualCharacterRange: nil)
            }
            if let textContainer {
                layoutManager.ensureLayout(for: textContainer)
                frame.size.height = max(100, ceil(layoutManager.usedRect(for: textContainer).height))
            }
        }
        pageRects = []
        var start: CGFloat = 0
        var glyph = 0
        var paragraphLocation = NSNotFound
        var paragraphStart: CGFloat = 0
        var insertedCoverBreak = false
        let text = textStorage.string as NSString
        while glyph < layoutManager.numberOfGlyphs {
            guard !abortCancelledPrint() else { return cancelledPageRange(range) }
            var effective = NSRange()
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
            let characters = layoutManager.characterRange(forGlyphRange: effective,
                                                          actualGlyphRange: nil)
            if !insertedCoverBreak, let coverBreakCharacter,
               characters.location >= coverBreakCharacter, line.minY > start {
                pageRects.append(NSRect(x: 0, y: start, width: bounds.width,
                                        height: line.minY - start))
                start = line.minY
                insertedCoverBreak = true
            }
            let paragraph = text.paragraphRange(for: characters)
            if paragraph.location != paragraphLocation {
                paragraphLocation = paragraph.location
                paragraphStart = line.minY
            }
            if line.maxY > start + printableHeight && line.minY > start {
                // Keep a short paragraph together when it crosses a page boundary.
                let nextStart = paragraphStart > start ? paragraphStart : line.minY
                pageRects.append(NSRect(x: 0, y: start, width: bounds.width,
                                        height: nextStart - start))
                start = nextStart
            }
            let nextGlyph = NSMaxRange(effective)
            guard nextGlyph > glyph else { break }
            glyph = nextGlyph
        }
        pageRects.append(NSRect(x: 0, y: start, width: bounds.width,
                                height: max(1, bounds.height - start)))
        range.pointee = NSRange(location: 1, length: pageRects.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        _ = abortCancelledPrint()
        guard page > 0, page <= pageRects.count else { return .zero }
        return pageRects[page - 1]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !abortCancelledPrint() else { return }
        super.draw(dirtyRect)
    }

    private func cancelledPageRange(_ range: NSRangePointer) -> Bool {
        // AppKit treats an empty page range or rectangle as a print error and
        // opens an alert. Keep valid geometry while suppressing cancelled drawing.
        pageRects = [NSRect(x: 0, y: 0, width: max(100, bounds.width),
                            height: max(1, min(printableHeight, bounds.height)))]
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    private func abortCancelledPrint() -> Bool {
        guard printCancellation?.isCancelled == true else { return false }
        // Cancelling the disposition before AppKit creates its graphics context
        // produces an error alert. Signal the job once page drawing has started.
        if let operation = NSPrintOperation.current, operation.context != nil {
            operation.printInfo.jobDisposition = .cancel
        }
        return true
    }
}

/// The task's cancellation handler may run while AppKit is rendering on the
/// main thread, so it cannot rely exclusively on a new main-actor task.
final class PrintCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

@MainActor
private final class PrintCompletion: NSObject {
    var continuation: CheckedContinuation<Bool, Never>?
    func cancel(_ operation: NSPrintOperation, window: NSWindow) {
        guard continuation != nil else { return }
        // NSPrintOperation has no public cancel() API. Use the documented job
        // disposition and end this operation's modal sheet if it is waiting.
        if operation.context != nil { operation.printInfo.jobDisposition = .cancel }
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
    }
    @objc func didRun(_ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?) {
        continuation?.resume(returning: success)
        continuation = nil
    }
}
