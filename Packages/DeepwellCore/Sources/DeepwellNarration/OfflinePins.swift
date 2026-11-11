import Foundation
import DeepwellMenu
import DeepwellIndex

/// Offline pinning (ticket 17): the phone keeps the Current Focus queue downloaded, each item's `.md` and its
/// `.narration/` folder, so it can be read and listened to in airplane mode. `pins` is pure (tested); the rest asks
/// iCloud to download and reads back how far it got.
public enum OfflinePins {
    public struct Pin: Equatable, Sendable {
        public var itemID: String
        public var item: URL
        public var narration: URL
    }

    /// How a pinned item's files stand on this device.
    public enum State: Equatable, Sendable { case downloaded, downloading, notDownloaded }

    /// One file's state as iCloud reports it.
    public enum FileState: Equatable, Sendable { case local, downloading, remote }

    /// What to keep downloaded for a queue: each entry whose item is in the index (by id → path relative to the
    /// library), in queue order, once each.
    public static func pins(queue: WeekQueue?, relativePaths: [String: String], library: URL) -> [Pin] {
        guard let queue else { return [] }
        var seen = Set<String>()
        return queue.entries.compactMap { e in
            guard let rel = relativePaths[e.itemID], seen.insert(e.itemID).inserted else { return nil }
            let item = library.appendingPathComponent(rel)
            return Pin(itemID: e.itemID, item: item, narration: NarrationSession.folder(forItemFile: item))
        }
    }

    /// The item file and every narration file (none if it was never narrated) decide the badge.
    public static func state(item: FileState, narration: [FileState]) -> State {
        let all = [item] + narration
        if all.allSatisfy({ $0 == .local }) { return .downloaded }
        if all.contains(.downloading) { return .downloading }
        return .notDownloaded
    }

    // MARK: iCloud

    /// Asks iCloud to download the item and its narration folder (each file in it, placeholders included).
    /// Harmless for files already local or outside iCloud.
    public static func request(_ pin: Pin, fileManager fm: FileManager = .default) {
        try? fm.startDownloadingUbiquitousItem(at: pin.item)
        try? fm.startDownloadingUbiquitousItem(at: pin.narration)
        for url in narrationFiles(pin, fileManager: fm) { try? fm.startDownloadingUbiquitousItem(at: url) }
    }

    public static func state(of pin: Pin, fileManager fm: FileManager = .default) -> State {
        state(item: fileState(pin.item, fileManager: fm), narration: narrationFiles(pin, fileManager: fm).map { fileState($0, fileManager: fm) })
    }

    /// The real URLs of the files in the narration folder (an evicted `.x.mp3.icloud` placeholder maps to `x.mp3`).
    static func narrationFiles(_ pin: Pin, fileManager fm: FileManager) -> [URL] {
        guard let names = try? fm.contentsOfDirectory(atPath: pin.narration.path) else { return [] }
        return names.map { name in
            let url = pin.narration.appendingPathComponent(name)
            return ICloudPlaceholder.realURL(forPlaceholder: url) ?? url
        }
    }

    static func fileState(_ url: URL, fileManager fm: FileManager) -> FileState {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey]
        guard let v = try? url.resourceValues(forKeys: keys), v.isUbiquitousItem == true else {
            // Not in iCloud (or not readable): local if the file itself is there, else remote (a placeholder or nothing yet).
            return fm.fileExists(atPath: url.path) ? .local : .remote
        }
        switch v.ubiquitousItemDownloadingStatus {
        case .current?, .downloaded?: return .local
        default: return v.ubiquitousItemIsDownloading == true ? .downloading : .remote
        }
    }
}
