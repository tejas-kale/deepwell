import Foundation
import DeepwellLibrary

/// Watches the library for changes.
/// - In the iCloud container: `NSMetadataQuery` over the ubiquitous Documents scope. It reports local writes, remote
///   changes arriving, download progress and conflicts. Evicted `.md` files are asked to download (the Mac indexes
///   every item), and files with unresolved conflicts are handed to `onConflicts`.
/// - In the local fallback (or a fixed folder): FSEvents (`FolderWatcher`) on macOS.
/// `onChange` runs on a background queue after a burst settles; `onConflicts` runs on a background queue too.
/// `onSharedStateChange` (container only) fires, on the main queue, when a file in `<library>/.deepwell/` (`menu.json`)
/// is added or changes; an evicted one is asked to download first. The iOS app refreshes Current Focus from it.
public final class LibraryWatcher: @unchecked Sendable {
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    #if os(macOS)
    private var folderWatcher: FolderWatcher?
    #endif
    private let work = DispatchQueue(label: "deepwell.librarywatcher")
    private let onChange: @Sendable () -> Void
    private let onConflicts: @Sendable ([URL]) -> Void
    private let onSharedStateChange: (@Sendable () -> Void)?
    private var pendingChange: DispatchWorkItem?
    private let latency: TimeInterval
    private let downloadsIssues: Bool

    /// `downloadsIssues` (the Mac, ticket 20): also download evicted files in `<library>/issues/` (originals and their
    /// `.pending.json` markers), so issues handed over from the phone reach the splitter. The phone leaves them evicted.
    public init(location: LibraryLocation, latency: TimeInterval = 0.5, downloadsIssues: Bool = false,
                onChange: @escaping @Sendable () -> Void,
                onConflicts: @escaping @Sendable ([URL]) -> Void = { _ in },
                onSharedStateChange: (@Sendable () -> Void)? = nil) {
        self.onChange = onChange
        self.onConflicts = onConflicts
        self.onSharedStateChange = onSharedStateChange
        self.latency = latency
        self.downloadsIssues = downloadsIssues
        if location.isUbiquitous {
            // NSMetadataQuery must be started on a thread with a run loop; the main one.
            if Thread.isMainThread { startQuery() }
            else { DispatchQueue.main.async { self.startQuery() } }
        } else {
            #if os(macOS)
            folderWatcher = FolderWatcher(url: location.url, latency: latency) { onChange() }
            #endif
        }
    }

    private func startQuery() {
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { [weak self] _ in
            self?.handle(q, items: nil)
        })
        observers.append(nc.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] note in
            let info = note.userInfo ?? [:]
            let changed = [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey]
                .flatMap { (info[$0] as? [NSMetadataItem]) ?? [] }
            self?.handle(q, items: changed)
        })
        query = q
        q.start()
    }

    /// `items` nil means "look at every result" (first gathering).
    private func handle(_ q: NSMetadataQuery, items: [NSMetadataItem]?) {
        q.disableUpdates()
        let list = items ?? (q.results as? [NSMetadataItem] ?? [])
        var toDownload: [URL] = [], conflicted: [URL] = []
        var sharedStateChanged = false
        for item in list {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            if Self.isSharedState(url) {
                if status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded { toDownload.append(url) }
                sharedStateChanged = true
                continue
            }
            if url.pathComponents.contains(where: { $0.hasPrefix(".") }) { continue }   // .deepwell/, .narration/: not items
            if Self.isIssueFile(url) {
                if downloadsIssues, status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded { toDownload.append(url) }
                if url.lastPathComponent.hasSuffix(".pending.json"),
                   (item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool) == true { conflicted.append(url) }
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            if status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded { toDownload.append(url) }
            if (item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool) == true { conflicted.append(url) }
        }
        q.enableUpdates()
        work.async { [onConflicts] in
            for url in toDownload { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
            if !conflicted.isEmpty { onConflicts(conflicted) }
        }
        scheduleChange()
        if sharedStateChanged, let onSharedStateChange { onSharedStateChange() }
    }

    /// A file directly in the library's `.deepwell/` folder (`menu.json`, later `tag-ops.jsonl`).
    static func isSharedState(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == ".deepwell" && !url.lastPathComponent.hasPrefix(".")
    }

    /// A file directly in the library's `issues/` folder (magazine originals and pending-split markers).
    static func isIssueFile(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "issues" && !url.lastPathComponent.hasPrefix(".")
    }

    private func scheduleChange() {
        pendingChange?.cancel()
        let item = DispatchWorkItem { [onChange] in onChange() }
        pendingChange = item
        work.asyncAfter(deadline: .now() + latency, execute: item)
    }

    public func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let q = query { DispatchQueue.main.async { q.stop() } }
        query = nil
        #if os(macOS)
        folderWatcher?.stop()
        folderWatcher = nil
        #endif
    }

    deinit { stop() }
}
