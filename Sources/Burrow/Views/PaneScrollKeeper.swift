import AppKit
import SwiftUI

/// Bounded, non-observable navigation geometry, owned by one tab.
@MainActor
final class PaneScrollHistory {
    /// The model supplies its live context. A coalesced A→B→A transition must
    /// never leave a separate recording gate waiting for a missing view update.
    var contextProvider: (() -> String?)?
    func accepts(_ context: String) -> Bool { contextProvider.map { $0() == context } ?? true }
    private var offsets: [String: CGFloat] = [:]
    private var recency: [String] = []
    private var expandedPaths: [String: Set<String>] = [:]
    func expandedFolders(for context: String) -> Set<String> { expandedPaths[context] ?? [] }
    func recordExpandedFolders(_ paths: Set<String>, for context: String) {
        expandedPaths[context] = paths
        touch(context)
    }
    private func touch(_ context: String) {
        recency.removeAll { $0 == context }
        recency.append(context)
        if recency.count > 100 {
            let evicted = recency.removeFirst()
            offsets.removeValue(forKey: evicted)
            expandedPaths.removeValue(forKey: evicted)
        }
    }
    func offset(for context: String) -> CGFloat { offsets[context] ?? 0 }
    func record(_ offset: CGFloat, for context: String) {
        guard accepts(context), offset.isFinite, offset >= 0 else { return }
        offsets[context] = offset
        touch(context)
    }
}

/// Observe the native clip view rather than publishing SwiftUI state on every
/// scroll tick. Restores pixel offsets after the new document has been laid out.
struct PaneScrollKeeper: NSViewRepresentable {
    let history: PaneScrollHistory
    let context: String
    var contentIsEmpty = false
    func makeNSView(context: Context) -> ScrollKeeperView { ScrollKeeperView() }
    func updateNSView(_ view: ScrollKeeperView, context: Context) {
        view.update(history: history, context: self.context, contentIsEmpty: contentIsEmpty)
    }
    static func dismantleNSView(_ view: ScrollKeeperView, coordinator: ()) { view.detach() }
}

final class ScrollKeeperView: NSView {
    private var history: PaneScrollHistory?
    private(set) var currentContext: String?
    private weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?
    private weak var documentView: NSView?
    private var documentObserver: NSObjectProtocol?
    private var contentWasEmpty = false
    private var pendingOffset: CGFloat?
    private var restoring = false
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(history: PaneScrollHistory, context: String, contentIsEmpty: Bool = false) {
        let needsRestore = self.history !== history || currentContext != context || scrollView == nil
            || (contentIsEmpty && !contentWasEmpty)
        contentWasEmpty = contentIsEmpty
        guard needsRestore else { return }
        self.history = history
        currentContext = context
        pendingOffset = contentIsEmpty ? 0 : history.offset(for: context)
        attach()
        // Restoration belongs to this layout/display transaction. Dispatching
        // it onto the next main-queue turn exposes a frame at the old offset.
        needsLayout = true
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        attach()
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        attach()
        restoreBeforeDisplay(finalLayout: false)
    }

    override func viewWillDraw() {
        // SwiftUI may resize its lazy document after our own layout callback.
        // This is the last synchronous opportunity before the new pixels draw.
        super.viewWillDraw()
        attach()
        restoreBeforeDisplay(finalLayout: true)
    }

    private func attach() {
        guard let scroll = enclosingScrollView else { return }
        if scrollView !== scroll {
            detach()
            scrollView = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record() }
            }
        }
        if documentView !== scroll.documentView {
            if let documentObserver { NotificationCenter.default.removeObserver(documentObserver) }
            documentObserver = nil
            documentView = scroll.documentView
            guard let documentView else { return }
            documentView.postsFrameChangedNotifications = true
            documentObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                object: documentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restoreBeforeDisplay(finalLayout: false)
                }
            }
        }
    }

    private func restoreBeforeDisplay(finalLayout: Bool) {
        guard let y = pendingOffset, let scroll = scrollView,
              let currentContext, history?.accepts(currentContext) == true else { return }
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        // Do not clamp against the previous folder's shorter document during
        // an intermediate layout. A genuinely shortened folder clamps at draw.
        guard finalLayout || y <= maxY else { return }
        restoring = true
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: min(y, maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
        // Keep the target through intermediate document-frame notifications:
        // SwiftUI can reset clip bounds again later in the same layout pass.
        if finalLayout { pendingOffset = nil }
        restoring = false
        if finalLayout { record() }
    }

    private func record() {
        guard !restoring, pendingOffset == nil, let scrollView, let currentContext else { return }
        history?.record(max(0, scrollView.contentView.bounds.minY), for: currentContext)
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let documentObserver { NotificationCenter.default.removeObserver(documentObserver) }
        observer = nil
        documentObserver = nil
        documentView = nil
        scrollView = nil
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let documentObserver { NotificationCenter.default.removeObserver(documentObserver) }
    }
}
