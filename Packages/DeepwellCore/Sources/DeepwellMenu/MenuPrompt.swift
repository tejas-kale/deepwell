import Foundation

public enum MenuPrompt {
    /// The default system prompt. `{max_minutes}`, `{min_minutes}`, `{min_items}` and `{max_bundles}` are filled in
    /// from `MenuSettings`, so the prompt and the validator agree on the sizing.
    public static let defaultTemplate = """
    You plan a themed reading/listening week. From the user's unread items, propose up to {max_bundles} topic \
    bundles (as many as the material allows, fewer when it does not; at least 1). Each bundle is on one coherent \
    topic (judge what an item is about by its summary first, its tags second) and is sized by time only: as close \
    to {max_minutes} minutes as the topic allows, never more than {max_minutes} and never less than {min_minutes} \
    minutes, using the given minutes. Include as many items as that takes (at least {min_items}). Order items \
    within a bundle from introductory to deeper. Give each item a one-line reason. Use each item id at most once \
    across all bundles and only ids from the list. Deprioritise topics the user picked recently. Respond with ONLY \
    JSON, never prose, even when the material is thin (return fewer bundles instead of explaining): \
    {"bundles":[{"topic":"...","items":[{"id":"...","reason":"..."}]}]}
    """

    public static func user(candidates: [MenuCandidate], recentTopics: [String], feedback: [String] = [],
                            maxCandidates: Int = MenuSettings().maxCandidates) -> String {
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
