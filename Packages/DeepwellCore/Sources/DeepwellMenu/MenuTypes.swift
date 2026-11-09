import Foundation
import DeepwellModel

/// How the weekly menu is built: the model call and the sizing rules. Stored by the app (Settings > Weekly Menu).
/// Every field has a default, so stored JSON from an older version decodes to defaults for what it lacks.
/// Bundles are sized by time only, with as many items as that takes (libraries are mostly 5-25 minute articles,
/// so a fixed item count cannot also hit a time budget).
public struct MenuSettings: Codable, Equatable, Sendable {
    public static let defaultModel = "claude-sonnet-5-5"
    public static let efforts = ["low", "medium", "high", "max"]

    public var model = defaultModel
    /// `output_config.effort`. Thinking counts against the 16k output budget, so higher effort risks a cut-off reply.
    public var effort = "medium"
    /// System prompt template; `{max_minutes}`, `{min_minutes}`, `{min_items}` and `{max_bundles}` are filled in.
    public var promptTemplate = MenuPrompt.defaultTemplate
    /// The aim for a bundle, never exceeded (validation cuts the deepest items).
    public var maxBundleMinutes = 240
    /// Anything thinner is not a week's focus and is dropped.
    public var minBundleMinutes = 150
    public var minItems = 3
    /// At least 1 bundle is always accepted: a small library may only hold enough for one good bundle.
    public var maxBundles = 5
    /// Reading speed for items without a duration (stated assumption).
    public var wordsPerMinute = 230
    /// Cap on items sent to the model (newest captured first); keeps the prompt bounded.
    public var maxCandidates = 250
    /// How many recent picks are sent as "recently picked topics" to deprioritise.
    public var recentPicks = 4

    public init() {}

    public var bundleCount: ClosedRange<Int> { 1...max(1, maxBundles) }

    /// The system prompt with the sizing numbers filled in.
    public var systemPrompt: String {
        promptTemplate
            .replacingOccurrences(of: "{max_minutes}", with: "\(maxBundleMinutes)")
            .replacingOccurrences(of: "{min_minutes}", with: "\(minBundleMinutes)")
            .replacingOccurrences(of: "{min_items}", with: "\(minItems)")
            .replacingOccurrences(of: "{max_bundles}", with: "\(maxBundles)")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MenuSettings()
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        effort = try c.decodeIfPresent(String.self, forKey: .effort) ?? d.effort
        promptTemplate = try c.decodeIfPresent(String.self, forKey: .promptTemplate) ?? d.promptTemplate
        maxBundleMinutes = try c.decodeIfPresent(Int.self, forKey: .maxBundleMinutes) ?? d.maxBundleMinutes
        minBundleMinutes = try c.decodeIfPresent(Int.self, forKey: .minBundleMinutes) ?? d.minBundleMinutes
        minItems = try c.decodeIfPresent(Int.self, forKey: .minItems) ?? d.minItems
        maxBundles = try c.decodeIfPresent(Int.self, forKey: .maxBundles) ?? d.maxBundles
        wordsPerMinute = try c.decodeIfPresent(Int.self, forKey: .wordsPerMinute) ?? d.wordsPerMinute
        maxCandidates = try c.decodeIfPresent(Int.self, forKey: .maxCandidates) ?? d.maxCandidates
        recentPicks = try c.decodeIfPresent(Int.self, forKey: .recentPicks) ?? d.recentPicks
    }
}

public enum MenuSizing {
    /// Minutes still needed for an item: `duration_minutes`, else `word_count / wpm` rounded up; nil if neither is
    /// known (such items are not eligible because they cannot be sized). Partly-read items count what is left.
    public static func remainingMinutes(_ item: Item, wordsPerMinute: Int = MenuSettings().wordsPerMinute) -> Int? {
        let wpm = max(1, wordsPerMinute)
        let full: Int
        if let d = item.durationMinutes, d > 0 { full = d }
        else if let w = item.wordCount, w > 0 { full = (w + wpm - 1) / wpm }
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
    public static func eligible(from items: [Item], wordsPerMinute: Int = MenuSettings().wordsPerMinute) -> [MenuCandidate] {
        items.compactMap { i in
            guard i.status != .done, let m = MenuSizing.remainingMinutes(i, wordsPerMinute: wordsPerMinute) else { return nil }
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
