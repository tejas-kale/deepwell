import Foundation

/// How tags are compared everywhere (tagging, curation, conflict merges, the tag-ops log): case and separators don't
/// count, so "Machine Learning", "machine_learning" and "machine-learning" are one tag.
public enum TagName {
    /// Canonical comparison form: lowercase, runs of space/underscore/hyphen/newline/tab become one hyphen.
    public static func canonical(_ tag: String) -> String {
        let parts = tag.lowercased().split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" || $0 == "\n" || $0 == "\t" })
        return parts.joined(separator: "-")
    }
}
