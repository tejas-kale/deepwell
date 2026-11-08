import Foundation
import DeepwellModel

/// Sizing rules. Reading speed is a stated assumption: 230 words per minute.
public enum MenuSizing {
    public static let wordsPerMinute = 230
    public static let targetMinutes = 300          // about 5 hours
    public static let minBundleMinutes = 240       // 4 h
    public static let maxBundleMinutes = 360       // 6 h
    public static let bundleCount = 3...5
    public static let itemCount = 5...7

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

    public init(id: String, title: String, type: ItemType, tags: [String], minutes: Int) {
        self.id = id; self.title = title; self.type = type; self.tags = tags; self.minutes = minutes
    }

    /// Only unread or unfinished (status != done) items with a known length.
    public static func eligible(from items: [Item]) -> [MenuCandidate] {
        items.compactMap { i in
            guard i.status != .done, let m = MenuSizing.remainingMinutes(i) else { return nil }
            return MenuCandidate(id: i.id, title: i.title, type: i.type, tags: i.tags, minutes: m)
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
    case notEnoughItems(eligible: Int)
    case invalidModelOutput(String)
    case noSuchBundle
}
