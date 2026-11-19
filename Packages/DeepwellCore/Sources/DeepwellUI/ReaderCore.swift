import SwiftUI
import DeepwellModel
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct Metrics: Equatable { var offset: CGFloat = 0; var content: CGFloat = 0 }
private struct MetricsKey: PreferenceKey {
    static var defaultValue = Metrics()
    static func reduce(value: inout Metrics, nextValue: () -> Metrics) { value = nextValue() }
}

/// ScrollView that reports how far (0...1) the user has scrolled and restores the saved position.
///
/// While narrating with `following` on, it keeps the spoken word (`SpokenWordYKey`) in a comfortable band: when the word
/// drops below ~70% of the viewport (or above ~12%), the page moves once so the word sits at ~28%, like turning a page.
/// It never moves for every word, so it doesn't bob. The target comes from `ReadAlongScroll`: the block's real frame,
/// not a fraction of the whole article. A scroll gesture by the reader calls `onUserScroll`.
public struct ScrollProgressView<Content: View>: View {
    let initialProgress: Double
    var following = false
    var onUserScroll: () -> Void = {}
    let onProgress: (Double) -> Void
    let content: Content

    public init(initialProgress: Double, following: Bool = false, onUserScroll: @escaping () -> Void = {},
                onProgress: @escaping (Double) -> Void, @ViewBuilder content: () -> Content) {
        self.initialProgress = initialProgress
        self.following = following
        self.onUserScroll = onUserScroll
        self.onProgress = onProgress
        self.content = content()
    }

    @State private var restored = false
    @State private var offset: CGFloat = 0
    @State private var viewport: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var wordY: CGFloat?
    /// Last offset we asked the scroller for, so a repeat of the same word doesn't restart the animation.
    @State private var lastFollowTarget: CGFloat?
    @State private var scroller = NativeScroller()

    public var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .coordinateSpace(name: readerContentSpace)
                        .backgroundPreferenceValue(SpokenWordAnchorKey.self) { spoken in
                            GeometryReader { g in
                                let wordY: CGFloat? = spoken.flatMap { mark in
                                    let frame = g[mark.anchor]
                                    return ReadAlongScroll.wordY(blockMinY: frame.minY, blockHeight: frame.height,
                                                                  wordFraction: mark.fraction, contentHeight: g.size.height)
                                }
                                Color.clear
                                    .preference(key: MetricsKey.self, value: Metrics(offset: -g.frame(in: .named("reader")).minY, content: g.size.height))
                                    .preference(key: SpokenWordYKey.self, value: wordY)
                            }
                        }
                        .background(ScrollViewFinder(scroller: scroller, onUserScroll: { onUserScroll() }))
                        .id("content")
                }
                .coordinateSpace(name: "reader")
                .onPreferenceChange(SpokenWordYKey.self) { y in
                    wordY = y
                    keepWordInView(force: false)
                }
                .onChange(of: following) {
                    if following {
                        keepWordInView(force: true)
                    } else {
                        lastFollowTarget = nil
                    }
                }
                .onPreferenceChange(MetricsKey.self) { m in
                    offset = m.offset
                    contentHeight = m.content
                    viewport = outer.size.height
                    let scrollable = m.content - outer.size.height
                    if !restored {
                        guard m.content > 0 else { return }
                        restored = true
                        // Restore: scroll so the saved fraction sits at the top.
                        if initialProgress > 0, initialProgress < 1, scrollable > 0 {
                            DispatchQueue.main.async {
                                proxy.scrollTo("content", anchor: UnitPoint(x: 0.5, y: initialProgress))
                            }
                        }
                        keepWordInView(force: false)
                        return
                    }
                    guard scrollable > 0 else { onProgress(1); keepWordInView(force: false); return }
                    onProgress(min(max(m.offset / scrollable, 0), 1))
                    // Word y can arrive before the content height. Once both exist, follow.
                    keepWordInView(force: false)
                }
            }
        }
    }

    private func keepWordInView(force: Bool) {
        guard following, let y = wordY else { return }
        guard let target = ReadAlongScroll.targetOffset(wordY: y, viewport: viewport, contentHeight: contentHeight,
                                                         currentOffset: offset, force: force) else { return }
        if !force, let lastFollowTarget, abs(lastFollowTarget - target) < 4 { return }
        // Only remember the target when the scroller actually moved. On iPhone, a Jump during deceleration used to
        // no-op while still recording lastFollowTarget, so later follow-along skipped the same offset.
        if scroller.scroll(to: target, force: force) {
            lastFollowTarget = target
        }
    }
}

#if os(macOS)
/// The AppKit scroll view under a SwiftUI `ScrollView`: animated programmatic scrolling, and real scroll gestures
/// (`willStartLiveScroll`) told apart from our own.
@MainActor
final class NativeScroller {
    weak var scrollView: NSScrollView?
    private var observer: NSObjectProtocol?
    var onUserScroll: () -> Void = {}

    func attach(_ sv: NSScrollView?) {
        guard let sv, sv !== scrollView else { return }
        scrollView = sv
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: sv, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onUserScroll() }
        }
    }

    /// Scrolls so the top of the viewport sits `contentOffsetY` points down the article (top-down), clamped, eased.
    /// Returns whether a scroll was started. `force` is unused on macOS (kept for the shared call site).
    @discardableResult
    func scroll(to contentOffsetY: CGFloat, force: Bool = false) -> Bool {
        _ = force
        guard let sv = scrollView, let doc = sv.documentView, contentOffsetY.isFinite, doc.frame.height > 1 else { return false }
        let clip = sv.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let topDown = min(max(contentOffsetY, 0), maxY)
        var origin = clip.bounds.origin
        // The clip view is flipped. SwiftUI's document is too, so a larger bounds origin shows content further
        // down. A non-flipped document keeps y = 0 at the bottom — the end of the article — so the same top-down
        // offset is measured up from that end. Setting the origin absolutely avoids walking there by a bad delta.
        origin.y = doc.isFlipped ? topDown : (maxY - topDown)
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        guard abs(target.y - clip.bounds.origin.y) > 4 else { return false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(target)
        } completionHandler: {
            sv.reflectScrolledClipView(clip)
        }
        return true
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

private struct ScrollViewFinder: NSViewRepresentable {
    let scroller: NativeScroller
    let onUserScroll: () -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        scroller.onUserScroll = onUserScroll
        DispatchQueue.main.async { scroller.attach(v.enclosingScrollView) }
    }
}
#else
/// The UIKit scroll view under a SwiftUI `ScrollView` (ticket 17): eased programmatic scrolling for narration
/// follow-along, and the reader's own drags (the pan gesture beginning) told apart from our scrolls.
@MainActor
final class NativeScroller: NSObject {
    weak var scrollView: UIScrollView?
    var onUserScroll: () -> Void = {}

    func attach(_ sv: UIScrollView?) {
        guard let sv, sv !== scrollView else { return }
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
        scrollView = sv
        sv.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        if g.state == .began { onUserScroll() }
    }

    /// Scrolls so the top of the viewport sits `contentOffsetY` points down the article (top-down), clamped, eased.
    /// Returns whether a scroll was started. Follow-along never fights a live drag or coast; Jump to current (`force`)
    /// stops deceleration first so the jump is not dropped (issue #5).
    @discardableResult
    func scroll(to contentOffsetY: CGFloat, force: Bool = false) -> Bool {
        guard let sv = scrollView, contentOffsetY.isFinite else { return false }
        if sv.isDragging { return false }
        if sv.isDecelerating {
            guard force else { return false }
            // Kill momentum so setContentOffset is not ignored until the coast ends.
            sv.setContentOffset(sv.contentOffset, animated: false)
        }
        let inset = sv.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, sv.contentSize.height + inset.bottom - sv.bounds.height)
        let y = min(max(contentOffsetY, minY), maxY)
        guard abs(y - sv.contentOffset.y) > 4 else { return false }
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
            sv.contentOffset.y = y
        }
        return true
    }
}

/// Finds the enclosing `UIScrollView` by walking up from a zero-size view placed in the scrolled content.
private struct ScrollViewFinder: UIViewRepresentable {
    let scroller: NativeScroller
    let onUserScroll: () -> Void
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        return v
    }
    func updateUIView(_ v: UIView, context: Context) {
        scroller.onUserScroll = onUserScroll
        DispatchQueue.main.async { scroller.attach(Self.enclosingScrollView(of: v)) }
    }
    private static func enclosingScrollView(of v: UIView) -> UIScrollView? {
        var s = v.superview
        while let view = s, !(view is UIScrollView) { s = view.superview }
        return s as? UIScrollView
    }
}
#endif

/// Title block: headline, then "Author · site · 12 min read" and an "Open original" link instead of the raw URL.
public struct ArticleHeader: View {
    let item: Item
    #if !os(macOS)
    @Environment(\.openURL) private var openURL
    #endif

    public init(item: Item) { self.item = item }

    /// Seam: the Mac opens Safari specifically; iOS hands the link to the system.
    private func open(_ url: URL) {
        #if os(macOS)
        openInSafari(url)
        #else
        openURL(url)
        #endif
    }

    private var site: String? {
        guard let host = item.sourceURL?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var readTime: String? {
        guard let w = item.wordCount, w > 0 else { return nil }
        return "\(max(1, Int((Double(w) / 230).rounded()))) min read"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let url = item.sourceURL {
                Button { open(url) } label: {
                    Text(item.title).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .font(.system(size: 34, weight: .bold, design: .serif)).lineSpacing(2)
                #if os(macOS)
                .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                #endif
                .help("Open in Safari")
            } else {
                Text(item.title).font(.system(size: 34, weight: .bold, design: .serif)).lineSpacing(2)
            }
            HStack(spacing: 6) {
                Text([item.author, site, readTime].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                if let url = item.sourceURL {
                    Text("·")
                    Button("Open original") { open(url) }.linkButtonStyle()
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            Divider().padding(.top, 6)
        }
    }
}

#if os(macOS)
/// Opens a web page in Safari specifically (falls back to the default browser if Safari can't be found).
func openInSafari(_ url: URL) {
    let ws = NSWorkspace.shared
    guard let safari = ws.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { ws.open(url); return }
    ws.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration()) { _, error in
        if error != nil { DispatchQueue.main.async { ws.open(url) } }
    }
}
#endif
