import Foundation

public enum MenuPrompt {
    /// Cap on candidates sent (in index order, newest captured first); keeps the prompt bounded.
    public static let maxCandidates = 250

    public static let system = """
    You plan a themed reading/listening week. From the user's unread items, propose up to 5 topic bundles \
    (3 to 5 when the material allows, fewer when it does not; at least 1). Each bundle is on one coherent topic \
    (judge what an item is about by its summary first, its tags second) and is sized by time only: as close to \
    4 hours (240 minutes) as the topic allows, never more than 240 and never less than 150 minutes, using the \
    given minutes. Include as many items as that takes (at least 3). Order items within a bundle from introductory \
    to deeper. Give each item a one-line reason. Use each item id at most once across all bundles and only ids \
    from the list. Deprioritise topics the user picked recently. Respond with ONLY JSON, never prose, even when \
    the material is thin (return fewer bundles instead of explaining): \
    {"bundles":[{"topic":"...","items":[{"id":"...","reason":"..."}]}]}
    """

    public static func user(candidates: [MenuCandidate], recentTopics: [String], feedback: [String] = []) -> String {
        var lines = ["Recently picked topics (deprioritise): " + (recentTopics.isEmpty ? "none" : recentTopics.joined(separator: ", ")),
                     "", "Items (id | title | type | tags | minutes | summary):"]
        for c in candidates.prefix(maxCandidates) {
            lines.append("\(c.id) | \(c.title) | \(c.type.rawValue) | \(c.tags.joined(separator: ",")) | \(c.minutes) | \(c.summary)")
        }
        if !feedback.isEmpty {
            lines += ["", "Your previous answer had problems, fix them:"] + feedback.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}
