import Foundation

/// The "needs transcript" marker for items saved without published captions (ticket 05 writes it,
/// ticket 06 on-device transcription consumes it).
///
/// Contract for ticket 06:
/// - Frontmatter key `needs_transcript: true` is present on a `type: youtube` (or podcast) item whose
///   body is only a placeholder because no published transcript exists.
/// - After transcribing, replace the body with the transcript and call `clearNeedsTranscript()`
///   (the key is removed entirely; absence means "nothing to do").
/// - The key is not a first-class `Item` field: it travels in `extraFrontmatter`, so it survives
///   read/write round-trips and older code ignores it.
extension Item {
    public static let needsTranscriptKey = "needs_transcript"
    static let needsTranscriptLine = "\(needsTranscriptKey): true"

    public var needsTranscript: Bool {
        extraFrontmatter.contains { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == Item.needsTranscriptKey && parts[1].lowercased() == "true"
        }
    }

    public mutating func markNeedsTranscript() {
        guard !needsTranscript else { return }
        extraFrontmatter.append(Item.needsTranscriptLine)
    }

    public mutating func clearNeedsTranscript() {
        extraFrontmatter.removeAll { $0.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } == Item.needsTranscriptKey }
    }
}
