import SwiftUI
import AppKit

/// The three library columns, for View > Focus Sidebar / List / Reader (⌘1 / ⌘2 / ⌘3).
enum Pane: String, Hashable {
    case sidebar, list, reader
}

extension Notification.Name {
    /// `object` is a `Pane.rawValue`.
    static let deepwellFocusPane = Notification.Name("deepwell.focusPane")
}

/// Scrolls whatever scroll view fills the reader column, so the reader can be driven from the keyboard once it has
/// focus (↑ ↓, Space / ⇧Space, Page Up / Down, Home / End). It works for every reader variant (article, transcript,
/// podcast, issue) without each one having to expose its scroll position.
@MainActor
final class ReaderScroller {
    fileprivate weak var probe: NSView?

    enum Amount { case line(Int), page(Int), top, bottom }

    func scroll(_ amount: Amount) {
        guard let sv = target(), let doc = sv.documentView else { return }
        let clip = sv.contentView
        let visible = clip.bounds.height
        let maxY = max(0, doc.frame.height - visible)
        var y = clip.bounds.origin.y
        let down: CGFloat = doc.isFlipped ? 1 : -1
        switch amount {
        case .line(let n): y += CGFloat(n) * 48 * down
        case .page(let n): y += CGFloat(n) * (visible - 48) * down
        case .top: y = doc.isFlipped ? 0 : maxY
        case .bottom: y = doc.isFlipped ? maxY : 0
        }
        y = min(max(y, 0), maxY)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: y))
        } completionHandler: {
            Task { @MainActor in sv.reflectScrolledClipView(clip) }
        }
    }

    /// The largest vertically scrollable NSScrollView whose frame lies inside the reader column.
    private func target() -> NSScrollView? {
        guard let probe, let root = probe.window?.contentView else { return nil }
        let column = probe.convert(probe.bounds, to: nil).insetBy(dx: -2, dy: -2)
        var best: (NSScrollView, CGFloat)?
        func walk(_ v: NSView) {
            if let sv = v as? NSScrollView, sv.hasVerticalScroller || (sv.documentView?.frame.height ?? 0) > sv.contentView.bounds.height {
                let f = sv.convert(sv.bounds, to: nil)
                if column.contains(f), f.width * f.height > (best?.1 ?? 0) { best = (sv, f.width * f.height) }
            }
            v.subviews.forEach(walk)
        }
        walk(root)
        return best?.0
    }
}

/// Invisible view behind the reader column; it only marks where the column is.
struct ReaderScrollProbe: NSViewRepresentable {
    let scroller: ReaderScroller
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        scroller.probe = v
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { scroller.probe = v }
}

extension View {
    /// Reader-column key handling; only active while the reader has focus.
    func readerScrollKeys(_ s: ReaderScroller) -> some View {
        onKeyPress(keys: [.upArrow, .downArrow, .space, .pageUp, .pageDown, .home, .end]) { press in
            switch press.key {
            case .upArrow: s.scroll(.line(-1))
            case .downArrow: s.scroll(.line(1))
            case .space: s.scroll(.page(press.modifiers.contains(.shift) ? -1 : 1))
            case .pageUp: s.scroll(.page(-1))
            case .pageDown: s.scroll(.page(1))
            case .home: s.scroll(.top)
            case .end: s.scroll(.bottom)
            default: return .ignored
            }
            return .handled
        }
    }
}
