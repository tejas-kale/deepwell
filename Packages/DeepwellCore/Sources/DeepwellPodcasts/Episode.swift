import Foundation
import DeepwellModel

/// Everything Deepwell learns about a podcast episode before saving it.
public struct PodcastEpisode: Equatable, Sendable {
    public var title: String
    public var show: String?
    public var durationMinutes: Int?
    public var audioURL: URL
    /// A transcript the publisher offers (`<podcast:transcript>`), if any.
    public var transcriptURL: URL?
    public var transcriptType: String?
    public var sourceURL: URL

    public init(title: String, show: String?, durationMinutes: Int?, audioURL: URL,
                transcriptURL: URL? = nil, transcriptType: String? = nil, sourceURL: URL) {
        self.title = title; self.show = show; self.durationMinutes = durationMinutes; self.audioURL = audioURL
        self.transcriptURL = transcriptURL; self.transcriptType = transcriptType; self.sourceURL = sourceURL
    }
}

extension Item {
    public static let audioURLKey = "audio_url"

    /// The episode's audio file, stored in extra frontmatter so older code ignores it and round-trips keep it.
    public var audioURL: URL? {
        for line in extraFrontmatter {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == Item.audioURLKey {
                return URL(string: parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'")))
            }
        }
        return nil
    }

    public mutating func setAudioURL(_ url: URL) {
        extraFrontmatter.removeAll { $0.hasPrefix("\(Item.audioURLKey):") }
        extraFrontmatter.append("\(Item.audioURLKey): \"\(url.absoluteString)\"")
    }
}
