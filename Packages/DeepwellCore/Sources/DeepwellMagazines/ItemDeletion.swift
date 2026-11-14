import Foundation
import DeepwellModel
import DeepwellLibrary

/// Deletes one item from the library: its Markdown file and, for the last remaining article of a magazine issue,
/// the issue's original in `issues/` and its pending marker. Without that an issue with no articles left counts as
/// pending again (`MagazineService.pending`) and the next pass would split it again, bringing the article back.
///
/// Files only: the caller drops the item's index row (or lets the next `LibrarySync` pass do it). Other devices
/// follow through iCloud.
public enum ItemDeletion {
    public enum Disposal: Sendable {
        /// Move to the Trash (recoverable); a volume without a Trash falls back to removing the file.
        case trash
        /// Remove the file.
        case remove
    }

    public struct Outcome: Equatable, Sendable {
        /// Set when the item was its issue's last article and the original went with it.
        public var removedIssueID: String?
        public init(removedIssueID: String? = nil) { self.removedIssueID = removedIssueID }
    }

    @discardableResult
    public static func delete(relativePath: String, inLibrary library: URL, disposal: Disposal = .trash,
                              fileManager fm: FileManager = .default) throws -> Outcome {
        let url = library.appendingPathComponent(relativePath)
        let issueID = (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? FrontmatterCodec.decode($0) }?.item.issueID
        try dispose(url, disposal, fm)
        guard let issueID, !IssueStore.isSplit(issueID, inLibrary: library, fileManager: fm) else { return Outcome() }
        if let original = IssueStore.url(for: issueID, in: library, fileManager: fm) { try dispose(original, disposal, fm) }
        PendingIssue.remove(issueID: issueID, inLibrary: library)
        return Outcome(removedIssueID: issueID)
    }

    private static func dispose(_ url: URL, _ disposal: Disposal, _ fm: FileManager) throws {
        switch disposal {
        case .remove: try CoordinatedFile.delete(url, fileManager: fm)
        case .trash:
            do { try CoordinatedFile.trash(url, fileManager: fm) } catch { try CoordinatedFile.delete(url, fileManager: fm) }
        }
    }
}
