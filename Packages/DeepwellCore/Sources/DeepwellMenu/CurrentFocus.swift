import Foundation
import DeepwellModel

/// The week's picked queue as a reader sees it: the iOS app's read-only view of `<library>/.deepwell/menu.json`.
/// Loading never writes the file and never creates `.deepwell/` (the Mac is the only writer, docs/menu.md).
public struct CurrentFocus: Equatable, Sendable {
    /// nil: nothing picked yet (no file, an unreadable one, or a menu without a pick). The phone says
    /// "Build a menu on your Mac".
    public var queue: WeekQueue?
    /// The queue's rows in pick order with each item's current status and progress, from the device's own index.
    public var progress: QueueProgress?

    public init(queue: WeekQueue?, items: [Item]) {
        self.queue = queue
        self.progress = queue.map { QueueProgress.compute(queue: $0, items: items) }
    }

    /// Reads `<library>/.deepwell/menu.json` (coordinated, so iCloud downloads an evicted copy first; blocking, call
    /// it off the main thread) and maps it onto `items`.
    public static func load(library: URL, items: [Item]) -> CurrentFocus {
        let state = MenuStore(url: MenuStore.url(inLibrary: library)).load()
        return CurrentFocus(queue: state.queue, items: items)
    }

    /// Same queue, new item states (after an index refresh), without reading the file again.
    public func updating(items: [Item]) -> CurrentFocus { CurrentFocus(queue: queue, items: items) }
}
