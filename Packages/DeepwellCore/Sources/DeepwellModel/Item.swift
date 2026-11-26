import Foundation

public enum ItemType: String, Codable, Sendable, CaseIterable {
    case article
    case youtube
    case podcast
    case magazineArticle = "magazine-article"
}

public enum ItemStatus: String, Codable, Sendable, CaseIterable {
    case unread
    case reading
    case done
}

/// One library entry. This is exactly the frontmatter of the item's Markdown file.
public struct Item: Equatable, Sendable {
    public var id: String
    public var type: ItemType
    public var title: String
    public var sourceURL: URL?
    public var author: String?
    public var capturedAt: Date
    public var wordCount: Int?
    public var durationMinutes: Int?
    public var tags: [String]
    public var status: ItemStatus
    public var progress: Double
    /// When `status` became `done`, or nil when it is not done or was already done before this was recorded.
    public var finishedAt: Date?
    public var issueID: String?
    /// Frontmatter keys this version doesn't know, kept verbatim (raw YAML lines) so that
    /// rewriting a file never drops data written by a newer version or by the user.
    public var extraFrontmatter: [String]

    public init(
        id: String = UUID().uuidString.lowercased(),
        type: ItemType,
        title: String,
        sourceURL: URL? = nil,
        author: String? = nil,
        capturedAt: Date = Date(),
        wordCount: Int? = nil,
        durationMinutes: Int? = nil,
        tags: [String] = [],
        status: ItemStatus = .unread,
        progress: Double = 0,
        finishedAt: Date? = nil,
        issueID: String? = nil,
        extraFrontmatter: [String] = []
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.sourceURL = sourceURL
        self.author = author
        self.capturedAt = capturedAt
        self.wordCount = wordCount
        self.durationMinutes = durationMinutes
        self.tags = tags
        self.status = status
        self.progress = progress
        self.finishedAt = finishedAt
        self.issueID = issueID
        self.extraFrontmatter = extraFrontmatter
    }
}

/// A parsed item file: frontmatter plus Markdown body.
public struct ItemDocument: Equatable, Sendable {
    public var item: Item
    public var body: String
    public init(item: Item, body: String) {
        self.item = item
        self.body = body
    }
}
