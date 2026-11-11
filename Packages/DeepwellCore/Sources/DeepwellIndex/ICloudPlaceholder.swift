import Foundation

/// Evicted iCloud files. Current macOS keeps an evicted file at its own path with no data (its download status says
/// "not downloaded"); older systems left a `.<name>.icloud` stub. Both are handled: download status where the system
/// reports it, stubs otherwise.
public protocol UbiquitousDownloader: Sendable {
    func startDownloading(_ url: URL) throws
    /// False only for an iCloud file whose data is not on this device. Non-iCloud files are always downloaded.
    func isDownloaded(_ url: URL) -> Bool
}

extension UbiquitousDownloader {
    public func isDownloaded(_ url: URL) -> Bool { ICloudPlaceholder.isDownloaded(url) }
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

    /// Download status from the file's resource values; true when the system reports none (not an iCloud file).
    public static func isDownloaded(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values?.isUbiquitousItem == true, let status = values?.ubiquitousItemDownloadingStatus else { return true }
        return status != .notDownloaded
    }

    /// Makes sure the file at `url` exists locally. If only a placeholder exists, asks iCloud to download it
    /// and waits (polling) until the real file appears or `timeout` passes. Returns immediately for local files.
    public static func ensureLocal(
        _ url: URL,
        downloader: UbiquitousDownloader = SystemUbiquitousDownloader(),
        timeout: TimeInterval = 60,
        pollInterval: TimeInterval = 0.2,
        fileManager fm: FileManager = .default
    ) async throws {
        let local = { fm.fileExists(atPath: url.path) && downloader.isDownloaded(url) }
        if local() { return }
        if !fm.fileExists(atPath: url.path) {
            let stub = placeholderURL(forReal: url)
            guard fm.fileExists(atPath: stub.path) else { return } // genuinely missing: let the caller's read fail
        }
        try downloader.startDownloading(url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if local() { return }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        if local() { return }
        throw DownloadError.timedOut(url)
    }
}
