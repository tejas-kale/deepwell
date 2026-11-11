import Foundation
import DeepwellModel
import DeepwellLibrary

/// Reading-state rules.
public enum ReadingState {
    /// Scroll fraction at or above which an item counts as finished.
    public static let doneThreshold = 0.97

    /// Applies a scroll `progress` (0...1) to `item`. Progress only moves forward automatically; an item
    /// already `done` stays done. Starting to scroll turns `unread` into `reading`.
    public static func apply(progress: Double, to item: Item) -> Item {
        var i = item
        let p = min(max(progress, 0), 1)
        guard i.status != .done else { return i }
        i.progress = max(i.progress, p)
        if i.progress >= doneThreshold { i.status = .done; i.progress = 1 }
        else if i.progress > 0 { i.status = .reading }
        return i
    }
}

/// Writes status/progress back to an item's frontmatter.
public enum ItemFileUpdater {
    /// Reads `url`, lets `change` edit the item, and rewrites the file only if something changed. Body and
    /// unknown frontmatter keys are preserved. Returns the resulting document.
    @discardableResult
    public static func update(_ url: URL, _ change: (inout Item) -> Void) throws -> ItemDocument {
        var result: ItemDocument?
        try CoordinatedFile.update(url) { text in
            var doc = try FrontmatterCodec.decode(text)
            let before = doc.item
            change(&doc.item)
            result = doc
            return doc.item != before ? FrontmatterCodec.encode(doc) : nil
        }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return result
    }

    @discardableResult
    public static func setProgress(_ progress: Double, at url: URL) throws -> ItemDocument {
        try update(url) { $0 = ReadingState.apply(progress: progress, to: $0) }
    }

    @discardableResult
    public static func setStatus(_ status: ItemStatus, at url: URL) throws -> ItemDocument {
        try update(url) {
            $0.status = status
            if status == .done { $0.progress = 1 }
            if status == .unread { $0.progress = 0 }
        }
    }
}
