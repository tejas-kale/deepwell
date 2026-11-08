import Foundation

/// Evicted iCloud Drive files appear on disk as `.<name>.icloud` stubs. These helpers map stubs to real
/// files and download them on demand.
public protocol UbiquitousDownloader: Sendable {
    func startDownloading(_ url: URL) throws
}

public struct SystemUbiquitousDownloader: UbiquitousDownloader {
    public init() {}
    public func startDownloading(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

public enum ICloudPlaceholder {
    /// `/dir/.note.md.icloud` -> `/dir/note.md`; nil if `url` isn't a placeholder.
    public static func realURL(forPlaceholder url: URL) -> URL? {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud"), name.count > ".icloud".count + 1 else { return nil }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return url.deletingLastPathComponent().appendingPathComponent(real)
    }

    /// `/dir/note.md` -> `/dir/.note.md.icloud`.
    public static func placeholderURL(forReal url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    public enum DownloadError: Error, Equatable { case timedOut(URL) }

    /// Makes sure the file at `url` exists locally. If only a placeholder exists, asks iCloud to download it
    /// and waits (polling) until the real file appears or `timeout` passes. Returns immediately for local files.
    public static func ensureLocal(
        _ url: URL,
        downloader: UbiquitousDownloader = SystemUbiquitousDownloader(),
        timeout: TimeInterval = 60,
        pollInterval: TimeInterval = 0.2,
        fileManager fm: FileManager = .default
    ) async throws {
        if fm.fileExists(atPath: url.path) { return }
        let stub = placeholderURL(forReal: url)
        guard fm.fileExists(atPath: stub.path) else { return } // genuinely missing: let the caller's read fail
        try downloader.startDownloading(url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fm.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        if fm.fileExists(atPath: url.path) { return }
        throw DownloadError.timedOut(url)
    }
}
