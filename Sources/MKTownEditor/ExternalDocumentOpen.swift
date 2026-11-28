import AppKit
import Foundation

/// A URL delivered through Launch Services; file contents remain owned by DocumentGroup.
struct ExternalDocumentOpenRequest: Equatable {
    let fileURL: URL
    let line: Int?
    let isReadOnly: Bool

    init(fileURL: URL, line: Int? = nil, isReadOnly: Bool = false) {
        self.fileURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        self.line = line
        self.isReadOnly = isReadOnly
    }

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "mktowneditor",
              components.host?.lowercased() == "open",
              components.path.isEmpty || components.path == "/",
              components.fragment == nil,
              let items = components.queryItems,
              items.allSatisfy({ ["url", "line", "readonly"].contains($0.name) }),
              items.filter({ $0.name == "url" }).count == 1,
              items.filter({ $0.name == "line" }).count <= 1,
              items.filter({ $0.name == "readonly" }).count <= 1,
              let value = items.first(where: { $0.name == "url" })?.value,
              let file = URL(string: value), file.isFileURL, !file.path.isEmpty,
              ["md", "markdown", "mdown", "mkd", "txt"].contains(file.pathExtension.lowercased())
        else { return nil }
        let line: Int?
        if let item = items.first(where: { $0.name == "line" }) {
            guard let value = item.value, let number = Int(value), number > 0 else { return nil }
            line = number
        } else {
            line = nil
        }
        let readOnly = items.first(where: { $0.name == "readonly" })
        guard readOnly == nil || readOnly?.value == "1" else { return nil }
        self.init(fileURL: file, line: line, isReadOnly: readOnly != nil)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "mktowneditor"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: fileURL.absoluteString)]
        if let line { components.queryItems?.append(URLQueryItem(name: "line", value: String(line))) }
        if isReadOnly { components.queryItems?.append(URLQueryItem(name: "readonly", value: "1")) }
        return components.url!
    }

    @MainActor
    func open(in application: NSApplication) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            application.presentError(CocoaError(.fileNoSuchFile))
            return
        }
        let navigation = DocumentLinkNavigation.shared
        if let line { navigation.requestLine(in: fileURL, line: line) }
        let readOnlyRequest = isReadOnly ? navigation.requestReadOnlyOpen(for: fileURL) : nil
        NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, error in
            if let error {
                if line != nil { navigation.cancelLine(for: fileURL) }
                if let readOnlyRequest { navigation.cancelReadOnlyOpen(for: fileURL, id: readOnlyRequest) }
                application.presentError(error)
            }
        }
    }
}

@MainActor
final class ExternalDocumentOpenAppDelegate: NSObject, NSApplicationDelegate {
    private let selectionService = MarkdownSelectionService()
    private let activation = ApplicationActivation()
    private let application: () -> ActivationPolicyControlling

    /// `NSApplicationDelegateAdaptor` uses this initializer; the application is resolved lazily
    /// because `NSApp` may not exist yet when the delegate is created.
    override convenience init() {
        self.init(application: { NSApplication.shared })
    }

    init(application: @escaping () -> ActivationPolicyControlling) {
        self.application = application
    }

    var repairedActivationPolicy: Bool { activation.repairedPolicy }

    func applicationWillFinishLaunching(_ notification: Notification) {
        activation.applicationWillFinishLaunching(application())
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = selectionService
        activation.applicationDidFinishLaunching(application())
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            ExternalDocumentOpenRequest(url: url)?.open(in: application)
        }
    }
}
