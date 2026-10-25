import AppKit
import SwiftUI

/// Layout changes also move preview blocks. Only live scrolling may drive the source editor.
@MainActor
final class PreviewUserScrollMonitor: ObservableObject {
    private weak var scrollView: NSScrollView?
    private var origins: [Int: CGFloat] = [:]
    private var measuredScrollY: CGFloat?
    private var layoutIdentity: MarkdownAnalysis.Identity?
    private var awaitsUserScrollGeometry = false
    var onVisibleBlockChange: ((Int) -> Void)?

    func attach(to scrollView: NSScrollView?) {
        guard self.scrollView !== scrollView else { return }
        NotificationCenter.default.removeObserver(self,
            name: NSScrollView.didLiveScrollNotification, object: self.scrollView)
        if self.scrollView != nil {
            origins = [:]
            awaitsUserScrollGeometry = false
        }
        self.scrollView = scrollView
        measuredScrollY = scrollView?.contentView.bounds.origin.y
        if let scrollView {
            NotificationCenter.default.addObserver(self, selector: #selector(didLiveScroll(_:)),
                name: NSScrollView.didLiveScrollNotification, object: scrollView)
        }
    }

    func setLayout(_ identity: MarkdownAnalysis.Identity) {
        guard layoutIdentity !== identity else { return }
        layoutIdentity = identity
        origins = [:]
        awaitsUserScrollGeometry = false
    }

    func record(origins: [Int: CGFloat], identity: MarkdownAnalysis.Identity? = nil) {
        if let identity, layoutIdentity !== identity { return }
        self.origins = origins
        measuredScrollY = scrollView?.contentView.bounds.origin.y
        if awaitsUserScrollGeometry { synchronizeVisibleBlock() }
    }

    @objc private func didLiveScroll(_ notification: Notification) {
        guard let scrollView, notification.object as? NSScrollView === scrollView else { return }
        awaitsUserScrollGeometry = true
        synchronizeVisibleBlock()
    }

    private func synchronizeVisibleBlock() {
        guard let scrollView, let measuredScrollY, !origins.isEmpty else { return }
        // The notification can precede SwiftUI's geometry update. Translate the last
        // measured positions by the actual scroll delta so both event orders agree.
        let delta = scrollView.contentView.bounds.origin.y - measuredScrollY
        let visibleOrigins = origins.mapValues { $0 - delta }
        if let blockID = PreviewScrollSync.topBlockID(from: visibleOrigins) {
            awaitsUserScrollGeometry = false
            onVisibleBlockChange?(blockID)
        }
    }
}

struct PreviewUserScrollObserver: NSViewRepresentable {
    let monitor: PreviewUserScrollMonitor
    let identity: MarkdownAnalysis.Identity
    let onVisibleBlockChange: ((Int) -> Void)?

    func makeNSView(context: Context) -> ScrollProbe {
        let view = ScrollProbe()
        view.monitor = monitor
        monitor.setLayout(identity)
        monitor.onVisibleBlockChange = onVisibleBlockChange
        return view
    }

    func updateNSView(_ view: ScrollProbe, context: Context) {
        monitor.onVisibleBlockChange = onVisibleBlockChange
        monitor.setLayout(identity)
        view.monitor = monitor
        view.attach()
    }

    static func dismantleNSView(_ view: ScrollProbe, coordinator: ()) {
        view.monitor?.attach(to: nil)
    }

    final class ScrollProbe: NSView {
        weak var monitor: PreviewUserScrollMonitor?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        func attach() { monitor?.attach(to: enclosingScrollView) }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
