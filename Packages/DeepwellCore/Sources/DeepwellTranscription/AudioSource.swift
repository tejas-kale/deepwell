import Foundation
import DeepwellModel

/// Resolves and fetches the audio for an item. Local file URLs are used in place; remote ones are downloaded.
public struct AudioSource {
    public var resolvers: [ItemType: AudioURLResolver]
    public var downloader: AudioDownloader

    public init(resolvers: [ItemType: AudioURLResolver], downloader: AudioDownloader = URLSessionAudioDownloader()) {
        self.resolvers = resolvers
        self.downloader = downloader
    }

    /// Returns a local file and whether the caller should delete it afterwards.
    public func fetch(for item: Item, progress: @escaping @Sendable (Double) -> Void) async throws -> (file: URL, isTemporary: Bool) {
        guard let resolver = resolvers[item.type] else { throw TranscriptionError.noAudioResolver(item.type) }
        let url = try await resolver.audioURL(for: item)
        if url.isFileURL { return (url, false) }
        return (try await downloader.download(url, progress: progress), true)
    }
}

/// Reports that YouTube audio is unavailable to hosts that explicitly request a resolver.
public struct YouTubeAudioResolverStub: AudioURLResolver {
    public init() {}
    public func audioURL(for item: Item) async throws -> URL {
        throw TranscriptionError.audioUnavailable(
            "Audio for YouTube videos can't be fetched automatically (no sanctioned API), and this video has no published captions.")
    }
}

/// Plain URLSession download to a temp file; progress comes from the response's expected length.
public struct URLSessionAudioDownloader: AudioDownloader {
    public init() {}
    public func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw TranscriptionError.audioUnavailable("Audio download failed (HTTP \(http.statusCode)).")
        }
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("deepwell-\(UUID().uuidString).\(ext)")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        let total = response.expectedContentLength
        var buffer = Data()
        var written: Int64 = 0
        do {
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 256 * 1024 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if total > 0 { progress(min(1, Double(written) / Double(total))) }
                }
            }
            try handle.write(contentsOf: buffer)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
        progress(1)
        return dest
    }
}
