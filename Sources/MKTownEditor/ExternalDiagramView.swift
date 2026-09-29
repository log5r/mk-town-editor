import AppKit
import SwiftUI

struct ExternalDiagramView: View {
    let source: String
    let kind: ExternalDiagramKind
    @AppStorage("graphvizRendererPath") private var graphvizPath = ""
    @AppStorage("plantUMLJarPath") private var plantUMLPath = ""
    @State private var image: NSImage?
    @State private var error: String?
    @State private var isRendering = false
    @State private var showsSource = false
    @State private var generation = 0
    @State private var isPaused = false

    private var taskKey: String { "\(kind.rawValue):\(source):\(graphvizPath):\(plantUMLPath):\(generation):\(isPaused)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if kind == .graphviz {
                    Text("Graphviz図").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("PlantUML図").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isRendering { ProgressView().controlSize(.small) }
                Button(showsSource ? "図を表示" : "原文を表示") { showsSource.toggle() }
                    .buttonStyle(.borderless)
                if isRendering {
                    Button("中止") {
                        isPaused = true
                        isRendering = false
                        error = ExternalDiagramError.cancelled.localizedDescription
                    }
                        .buttonStyle(.borderless)
                } else if error != nil {
                    Button("再試行") { isPaused = false; generation += 1 }
                        .buttonStyle(.borderless)
                }
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if showsSource || error != nil {
                Text(source).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            } else if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .scaledToFit()
                    .accessibilityLabel(kind == .graphviz ? "Graphviz図" : "PlantUML図")
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: source) { _, _ in isPaused = false }
        .task(id: taskKey) {
            guard !isPaused else { return }
            image = nil
            error = nil
            isRendering = true
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let config = ExternalDiagramConfiguration(graphvizExecutable: graphvizPath,
                                                       plantUMLJar: plantUMLPath)
            do {
                let data = try await ExternalDiagramRenderer.render(source, kind: kind,
                                                                     configuration: config)
                guard !Task.isCancelled else { return }
                image = NSImage(data: data)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
            isRendering = false
        }
    }
}
