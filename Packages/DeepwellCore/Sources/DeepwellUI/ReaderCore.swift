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
/// It never moves for every word, so it doesn't bob. A scroll gesture by the reader calls `onUserScroll`.
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
    @State private var wordY: CGFloat?
    @State private var scroller = NativeScroller()

    private static var bandTop: CGFloat { 0.12 }
    private static var bandBottom: CGFloat { 0.70 }
    private static var settle: CGFloat { 0.28 }

    public var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .coordinateSpace(name: readerContentSpace)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: MetricsKey.self, value: Metrics(offset: -g.frame(in: .named("reader")).minY, content: g.size.height))
                        })
                        .background(ScrollViewFinder(scroller: scroller, onUserScroll: { onUserScroll() }))
                        .id("content")
                }
                .coordinateSpace(name: "reader")
                .onPreferenceChange(SpokenWordYKey.self) { y in
                    wordY = y
                    keepWordInView(force: false)
                }
                .onChange(of: following) { if following { keepWordInView(force: true) } }
                .onPreferenceChange(MetricsKey.self) { m in
                    offset = m.offset
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
                        return
                    }
                    guard scrollable > 0 else { onProgress(1); return }
                    onProgress(min(max(m.offset / scrollable, 0), 1))
                }
            }
        }
    }

    private func keepWordInView(force: Bool) {
        guard following, let y = wordY, viewport > 0 else { return }
        let inView = y - offset
        guard force || inView < viewport * Self.bandTop || inView > viewport * Self.bandBottom else { return }
        scroller.scroll(by: inView - viewport * Self.settle)
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

    /// Scrolls the content by `dy` points (positive: further down the article), clamped, eased.
    func scroll(by dy: CGFloat) {
        guard let sv = scrollView, let doc = sv.documentView, abs(dy) > 4 else { return }
        let clip = sv.contentView
        var origin = clip.bounds.origin
        origin.y += doc.isFlipped ? dy : -dy
        let target = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(target)
        } completionHandler: {
            sv.reflectScrolledClipView(clip)
        }
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

    /// Scrolls the content by `dy` points (positive: further down the article), clamped, eased.
    func scroll(by dy: CGFloat) {
        guard let sv = scrollView, abs(dy) > 4, !sv.isDragging, !sv.isDecelerating else { return }
        let inset = sv.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, sv.contentSize.height + inset.bottom - sv.bounds.height)
        let y = min(max(sv.contentOffset.y + dy, minY), maxY)
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
            sv.contentOffset.y = y
        }
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
