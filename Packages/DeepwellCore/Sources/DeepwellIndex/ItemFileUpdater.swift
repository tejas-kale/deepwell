import Foundation
import DeepwellModel
import DeepwellLibrary

/// Reading-state rules.
public enum ReadingState {
    /// Scroll fraction at or above which an item counts as finished.
    public static let doneThreshold = 0.97
    /// The readers (Mac and iOS) write scroll progress at most this long after the last forward move.
    public static let saveDelayNanoseconds: UInt64 = 700_000_000
    /// Smallest forward move worth a write; reaching `doneThreshold` always counts.
    public static let saveStep = 0.01

    /// Whether a scroll to `progress`, with `lastSaved` already recorded, should schedule a (debounced) write.
    public static func shouldSave(progress: Double, lastSaved: Double) -> Bool {
        progress > lastSaved + saveStep || progress >= doneThreshold
    }

    /// Applies a scroll `progress` (0...1) to `item`. Progress only moves forward automatically; an item
    /// already `done` stays done (and keeps `finishedAt`, including none: there is no backfill). Starting
    /// to scroll turns `unread` into `reading`. Crossing `doneThreshold` records `finishedAt` as `now`.
    public static func apply(progress: Double, to item: Item, now: Date = Date()) -> Item {
        var i = item
        let p = min(max(progress, 0), 1)
        guard i.status != .done else { return i }
        i.progress = max(i.progress, p)
        if i.progress >= doneThreshold {
            updateFinishedAt(&i, becoming: .done, now: now)
            i.status = .done
            i.progress = 1
        } else if i.progress > 0 {
            updateFinishedAt(&i, becoming: .reading, now: now)
            i.status = .reading
        }
        return i
    }

    /// Writes `finishedAt` only when status becomes `done`. An item that is already done keeps its date,
    /// or the absence of one. Any other status clears it. Call before assigning `status`.
    static func updateFinishedAt(_ item: inout Item, becoming status: ItemStatus, now: Date) {
        if status == .done {
            if item.status != .done { item.finishedAt = now }
        } else {
            item.finishedAt = nil
        }
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
    public static func setProgress(_ progress: Double, at url: URL, now: Date = Date()) throws -> ItemDocument {
        try update(url) { $0 = ReadingState.apply(progress: progress, to: $0, now: now) }
    }

    @discardableResult
    public static func setStatus(_ status: ItemStatus, at url: URL, now: Date = Date()) throws -> ItemDocument {
        try update(url) {
            ReadingState.updateFinishedAt(&$0, becoming: status, now: now)
            $0.status = status
            if status == .done { $0.progress = 1 }
            if status == .unread { $0.progress = 0 }
        }
    }
}
