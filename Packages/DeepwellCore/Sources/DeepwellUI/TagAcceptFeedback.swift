import DeepwellCuration
import DeepwellIndex
#if os(iOS)
import UIKit
#endif

/// What Accept All New should show. The tag list uses `summaries` even when the library model hasn't published
/// a new array yet, so the "new" badges clear in the same turn as the banner.
struct TagAcceptAllFeedback: Equatable, Sendable {
    enum Haptic: Equatable, Sendable { case success, warning, error }

    var message: String
    var summaries: [TagSummary]
    var haptic: Haptic

    /// `before` is the list on screen. `after` is the list the model reported once the curator returned.
    /// A nil result means the action didn't run. When `after` is unchanged, the flags are cleared here so the
    /// rows don't sit there looking untouched.
    static func make(before: [TagSummary], after: [TagSummary], result: CurationResult?) -> TagAcceptAllFeedback? {
        let pending = before.filter { $0.newCount > 0 }
        guard !pending.isEmpty else { return nil }
        guard let result else {
            return TagAcceptAllFeedback(message: "Couldn't accept new tags.", summaries: before, haptic: .error)
        }
        if result.updated.isEmpty && !result.failed.isEmpty {
            let n = result.failed.count
            return TagAcceptAllFeedback(message: "Couldn't update \(n) file\(n == 1 ? "" : "s").", summaries: before, haptic: .error)
        }
        let summaries = visibleSummaries(before: before, after: after)
        if !result.failed.isEmpty {
            let n = result.failed.count
            return TagAcceptAllFeedback(
                message: "Accepted new tags. \(n) file\(n == 1 ? "" : "s") could not be updated.",
                summaries: summaries, haptic: .warning)
        }
        let message = pending.count == 1 ? "Accepted \"\(pending[0].name)\"." : "Accepted \(pending.count) new tags."
        return TagAcceptAllFeedback(message: message, summaries: summaries, haptic: .success)
    }

    /// Prefer the index when it actually changed. Otherwise drop every new-flag so the list updates anyway.
    private static func visibleSummaries(before: [TagSummary], after: [TagSummary]) -> [TagSummary] {
        if !after.isEmpty, after != before { return after }
        return before.map { TagSummary(name: $0.name, itemCount: $0.itemCount, newCount: 0) }
    }
}

enum TagAcceptFeedbackPlayer {
    static func play(_ feedback: TagAcceptAllFeedback) {
        #if os(iOS)
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        switch feedback.haptic {
        case .success: generator.notificationOccurred(.success)
        case .warning: generator.notificationOccurred(.warning)
        case .error: generator.notificationOccurred(.error)
        }
        UIAccessibility.post(notification: .announcement, argument: feedback.message)
        #endif
    }
}
