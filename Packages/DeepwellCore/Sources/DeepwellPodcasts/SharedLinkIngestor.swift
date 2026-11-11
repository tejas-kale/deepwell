import Foundation
import DeepwellModel
import DeepwellLibrary
import DeepwellCapture
import DeepwellYouTube
import DeepwellTranscription

/// Resolves links shared through the Share Extension into library items.
///
/// - Podcast episode: uses the publisher's transcript when the feed offers a timed one; otherwise saves the item with
///   `needs_transcript: true` and `audio_url`, which the ticket 06 queue picks up via `PodcastAudioResolver`.
/// - YouTube link (from the YouTube app): follows the ticket 05 "no captions" path — a `youtube` item with title/channel
///   from oEmbed and the marker. Fetching published captions needs the page's player data, which only the Safari
///   extension has; so shared YouTube links are always transcribed (which is itself stubbed, see docs/transcription.md).
public struct SharedLinkIngestor: Sendable {
    public static let youtubePlaceholder =
        "_No published captions were available for this video. Deepwell will transcribe it on your Mac._"
    public static let podcastPlaceholder =
        "_This episode has no published transcript. Deepwell will transcribe it on your Mac._"

    let http: HTTPClient
    let resolver: PodcastResolver

    public init(http: HTTPClient = URLSessionHTTPClient()) {
        self.http = http
        self.resolver = PodcastResolver(http: http)
    }

    /// Builds the document to save for a shared URL. Throws for unsupported links or network failures.
    public func document(for url: URL, now: Date = Date()) async throws -> ItemDocument {
        switch SharedLink.classify(url) {
        case .youtube(let id): return try await youtubeDocument(id: id, now: now)
        case .unsupported: throw PodcastError.unsupportedLink(url.absoluteString)
        case let link:
            let episode = try await resolver.resolve(link, sourceURL: url)
            return await podcastDocument(episode, now: now)
        }
    }

    func podcastDocument(_ episode: PodcastEpisode, now: Date) async -> ItemDocument {
        var item = Item(type: .podcast, title: episode.title, sourceURL: episode.sourceURL, author: episode.show,
                        capturedAt: now, durationMinutes: episode.durationMinutes)
        item.setAudioURL(episode.audioURL)
        if let tURL = episode.transcriptURL, let data = try? await http.get(tURL) {
            let cues = TranscriptFile.parse(data, type: episode.transcriptType)
            let body = TranscriptFormatter.body(for: cues, item: item)
            if !body.isEmpty { return ItemDocument(item: item, body: body) }
        }
        item.markNeedsTranscript()
        return ItemDocument(item: item, body: Self.podcastPlaceholder)
    }

    func youtubeDocument(id: String, now: Date) async throws -> ItemDocument {
        let watch = YouTube.watchURL(id: id)
        var comps = URLComponents(string: "https://www.youtube.com/oembed")!
        comps.queryItems = [URLQueryItem(name: "url", value: watch.absoluteString), URLQueryItem(name: "format", value: "json")]
        struct OEmbed: Decodable { var title: String?; var author_name: String? }
        let meta = try? JSONDecoder().decode(OEmbed.self, from: try await http.get(comps.url!))
        var item = Item(type: .youtube, title: meta?.title ?? watch.absoluteString, sourceURL: watch,
                        author: meta?.author_name, capturedAt: now)
        item.markNeedsTranscript()
        return ItemDocument(item: item, body: Self.youtubePlaceholder)
    }

    public struct Outcome: Equatable, Sendable {
        public var saved: [URL] = []
        public var failures: [String] = []   // user-facing messages
    }

    /// What to do with a link that is neither a podcast nor a YouTube video.
    public enum UnsupportedLinks: Sendable {
        /// Mac: park it in the inbox's `unsupported/` and report it (open it in Safari and use the extension).
        case park
        /// iOS: save a link-only article (`CapturePayload.linkOnlyDocument`); the share sheet already told the user.
        case saveLinkOnly
    }

    /// Resolves every queued link and writes the items. Unsupported links are parked (or saved link-only); transient
    /// failures (network, library unavailable) leave the link queued so a later drain retries it.
    @discardableResult
    public func drain(inbox: CaptureInbox, into library: LibraryFolderStore, unsupported: UnsupportedLinks = .park) async -> Outcome {
        var outcome = Outcome()
        for (file, payload) in inbox.pendingLinks() {
            guard let url = URL(string: payload.url) else { inbox.finishLink(file, handled: false); continue }
            do {
                let doc: ItemDocument
                if unsupported == .saveLinkOnly, SharedLink.classify(url) == .unsupported {
                    doc = payload.linkOnlyDocument()
                } else {
                    doc = try await document(for: url)
                }
                let saved = try library.withAccess { folder in try ItemFileWriter.write(doc, into: folder) }
                inbox.finishLink(file, handled: true)
                outcome.saved.append(saved)
            } catch let e as PodcastError {
                switch e {
                case .unsupportedLink, .notAnEpisode, .notFound:
                    inbox.finishLink(file, handled: false)
                    outcome.failures.append(e.localizedDescription)
                case .http, .malformed:
                    outcome.failures.append(e.localizedDescription)   // retried on the next drain
                }
            } catch {
                outcome.failures.append(error.localizedDescription)  // network/library: retried next drain
            }
        }
        return outcome
    }
}

/// Audio for `podcast` items: the stored `audio_url`, or — if the file lacks one — re-resolved from the source link.
public struct PodcastAudioResolver: AudioURLResolver {
    let resolver: PodcastResolver
    public init(http: HTTPClient = URLSessionHTTPClient()) { resolver = PodcastResolver(http: http) }

    public func audioURL(for item: Item) async throws -> URL {
        if let u = item.audioURL { return u }
        guard let src = item.sourceURL else { throw TranscriptionError.audioUnavailable("This podcast item has no audio or source link.") }
        do { return try await resolver.resolve(SharedLink.classify(src), sourceURL: src).audioURL }
        catch { throw TranscriptionError.audioUnavailable(error.localizedDescription) }
    }
}
