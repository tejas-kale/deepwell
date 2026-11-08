import Foundation
import DeepwellModel

/// Sizing rules: bundles are sized by time only, up to 4 hours, with as many items as that takes (libraries are
/// mostly 5-25 minute articles, so a fixed item count cannot also hit a time budget).
/// Reading speed is a stated assumption: 230 words per minute.
public enum MenuSizing {
    public static let wordsPerMinute = 230
    public static let maxBundleMinutes = 240       // 4 h: the aim, never exceeded
    public static let minBundleMinutes = 150       // 2.5 h: anything thinner is not a week's focus
    public static let minItems = 3
    /// 1 is allowed because a small library may only hold enough for one good bundle.
    public static let bundleCount = 1...5

    /// Minutes still needed for an item: `duration_minutes`, else `word_count / wpm` rounded up; nil if neither is
    /// known (such items are not eligible because they cannot be sized). Partly-read items count what is left.
    public static func remainingMinutes(_ item: Item) -> Int? {
        let full: Int
        if let d = item.durationMinutes, d > 0 { full = d }
        else if let w = item.wordCount, w > 0 { full = (w + wordsPerMinute - 1) / wordsPerMinute }
        else { return nil }
        let left = Double(full) * (1 - min(max(item.progress, 0), 1))
        return max(1, Int(left.rounded(.up)))
    }
}

/// An eligible library item as shown to the model.
public struct MenuCandidate: Equatable, Sendable {
    public var id: String
    public var title: String
    public var type: ItemType
    public var tags: [String]
    public var minutes: Int
    /// One-sentence "what it is about" from auto-tagging; empty if the item has none yet.
    public var summary: String

    public init(id: String, title: String, type: ItemType, tags: [String], minutes: Int, summary: String = "") {
        self.id = id; self.title = title; self.type = type; self.tags = tags; self.minutes = minutes; self.summary = summary
    }

    /// Only unread or unfinished (status != done) items with a known length.
    public static func eligible(from items: [Item]) -> [MenuCandidate] {
        items.compactMap { i in
            guard i.status != .done, let m = MenuSizing.remainingMinutes(i) else { return nil }
            return MenuCandidate(id: i.id, title: i.title, type: i.type, tags: i.tags, minutes: m, summary: i.summary ?? "")
        }
    }
}

public struct MenuEntry: Codable, Equatable, Sendable {
    public var itemID: String
    public var title: String
    public var minutes: Int
    public var reason: String
}

public struct MenuBundle: Codable, Equatable, Sendable {
    public var topic: String
    public var entries: [MenuEntry]
    public var totalMinutes: Int { entries.reduce(0) { $0 + $1.minutes } }
}

public struct WeeklyMenu: Codable, Equatable, Sendable {
    public var builtAt: Date
    public var weekStart: Date
    public var bundles: [MenuBundle]
}

/// The picked bundle: an ordered list of item ids frozen at pick time. Progress is NOT stored here;
/// it is derived from the items' current status (see `QueueProgress`).
public struct WeekQueue: Codable, Equatable, Sendable {
    public var weekStart: Date
    public var pickedAt: Date
    public var topic: String
    public var entries: [MenuEntry]
}

public struct PickRecord: Codable, Equatable, Sendable {
    public var weekStart: Date
    public var topic: String
}

public enum MenuError: Error, Equatable {
    /// Not even one bundle's worth: too few eligible items or too few minutes in total.
    case notEnoughItems(eligible: Int, minutes: Int)
    case invalidModelOutput(String)
    case noSuchBundle
}
