import Foundation

public enum MenuPrompt {
    /// Cap on candidates sent (in index order, newest captured first); keeps the prompt bounded.
    public static let maxCandidates = 250

    public static let system = """
    You plan a themed reading/listening week. From the user's unread items, propose 3 to 5 topic bundles. \
    Each bundle has 5 to 7 items on one coherent topic, totalling about 5 hours (between 4 and 6 hours) using \
    the given minutes. Order items within a bundle from introductory to deeper. Give each item a one-line reason. \
    Use each item id at most once across all bundles and only ids from the list. Deprioritise topics the user \
    picked recently. Respond with ONLY JSON: \
    {"bundles":[{"topic":"...","items":[{"id":"...","reason":"..."}]}]}
    """

    public static func user(candidates: [MenuCandidate], recentTopics: [String], feedback: [String] = []) -> String {
        var lines = ["Recently picked topics (deprioritise): " + (recentTopics.isEmpty ? "none" : recentTopics.joined(separator: ", ")),
                     "", "Items (id | title | type | tags | minutes):"]
        for c in candidates.prefix(maxCandidates) {
            lines.append("\(c.id) | \(c.title) | \(c.type.rawValue) | \(c.tags.joined(separator: ",")) | \(c.minutes)")
        }
        if !feedback.isEmpty {
            lines += ["", "Your previous answer had problems, fix them:"] + feedback.map { "- \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}
