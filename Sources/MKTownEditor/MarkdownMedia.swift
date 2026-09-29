import AVKit
import SwiftUI

struct MarkdownMedia: Equatable, Sendable {
    enum Kind: String, Sendable {
        case audio, video

        var title: String {
            switch self {
            case .audio: String(localized: "音声")
            case .video: String(localized: "動画")
            }
        }

        var extensions: Set<String> {
            switch self {
            case .audio: ["mp3", "m4a", "aac", "wav"]
            case .video: ["mp4", "m4v", "mov"]
            }
        }
    }

    let kind: Kind
    let caption: String
    let path: String

    private static let pattern = try! NSRegularExpression(
        pattern: #"^!(audio|video)\[([^\]\r\n]*)\]\(([^\s()]+)\)$"#)

    init?(_ block: MarkdownBlock, dialect: MarkdownDialect) {
        guard dialect == .extended, block.kind == .paragraph else { return nil }
        let source = block.content as NSString
        guard let match = Self.pattern.firstMatch(in: block.content,
            range: NSRange(location: 0, length: source.length)),
              let kind = Kind(rawValue: source.substring(with: match.range(at: 1))) else { return nil }
        self.kind = kind
        caption = source.substring(with: match.range(at: 2))
        path = source.substring(with: match.range(at: 3))
    }

    func localURL(in context: DocumentContext) -> URL? {
        guard let url = context.resolveLocalResource(path),
              kind.extensions.contains(url.pathExtension.lowercased()),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return nil
        }
        return url
    }

    var label: String { "\(kind.title): \(caption.isEmpty ? path : caption)" }
}

struct MarkdownMediaPlayer: NSViewRepresentable {
    let media: MarkdownMedia
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = media.kind == .video
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player?.pause()
            view.player = AVPlayer(url: url)
        }
        view.showsFullScreenToggleButton = media.kind == .video
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

struct MarkdownMediaPreview: View {
    let media: MarkdownMedia
    let documentContext: DocumentContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(media.label).font(.caption).foregroundStyle(.secondary)
            if let url = media.localURL(in: documentContext) {
                MarkdownMediaPlayer(media: media, url: url)
                    .frame(height: media.kind == .audio ? 72 : 280)
                    .accessibilityLabel(media.label)
                Link("ファイルを開く", destination: url).font(.caption)
            } else {
                Text("ローカルの対応ファイルを再生できません")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
