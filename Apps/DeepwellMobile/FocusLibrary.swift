import Foundation
import Observation
import DeepwellModel
import DeepwellLibrary
import DeepwellIndex
import DeepwellMenu

/// The phone's view of the library: the per-device SQLite index (Application Support, built from the container and
/// kept current by `LibraryWatcher`'s NSMetadataQuery) and the Mac's pick from `.deepwell/menu.json` (read only).
@Observable
@MainActor
final class FocusLibrary {
    let location: LibraryLocation
    var folder: URL { location.url }

    /// nil until menu.json has been read once.
    private(set) var focus: CurrentFocus?
    /// Items being read (status `reading`), newest capture first.
    private(set) var inProgress: [IndexedItem] = []
    private(set) var errorMessage: String?
    /// True until the first index sync after launch has finished: rows for items not indexed yet say "Loading".
    private(set) var isIndexing = true

    @ObservationIgnored private var byID: [String: IndexedItem] = [:]
    @ObservationIgnored private var allItems: [Item] = []
    @ObservationIgnored private var index: LibraryIndex?
    @ObservationIgnored private var sync: LibrarySync?
    @ObservationIgnored private var watcher: LibraryWatcher?
    @ObservationIgnored private var menuPresenter: SharedFilePresenter?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var focusTask: Task<Void, Never>?

    @ObservationIgnored private let onSynced: @MainActor () -> Void

    /// `onSynced`: after each index sync (files arrived or changed), e.g. to tag what this device captured.
    init(location: LibraryLocation, onSynced: @escaping @MainActor () -> Void = {}) {
        self.location = location
        self.onSynced = onSynced
        do {
            let index = try LibraryIndex(url: LibraryIndex.defaultIndexURL())
            self.index = index
            self.sync = LibrarySync(root: location.url, index: index)
        } catch {
            errorMessage = "Could not open the index: \(error.localizedDescription)"
            return
        }
        reloadItems()
        scheduleSync()
        loadFocus()
        watcher = LibraryWatcher(location: location, onChange: { [weak self] in
            Task { @MainActor in self?.scheduleSync() }
        }, onConflicts: { [weak self] urls in
            // Background queue: merge each item's iCloud conflict versions into the current file (ticket 13's rules).
            var failures: [String] = []
            for url in urls {
                do { try ConflictResolver.resolve(url) } catch { failures.append(url.lastPathComponent) }
            }
            Task { @MainActor in
                if !failures.isEmpty { self?.errorMessage = "Could not merge iCloud conflicts in: \(failures.joined(separator: ", "))" }
                self?.scheduleSync()
            }
        }, onSharedStateChange: { [weak self] in
            Task { @MainActor in self?.loadFocus() }
        })
        // A second signal for a new pick: iCloud coordinates its writes of menu.json, which reaches this presenter.
        menuPresenter = SharedFilePresenter(url: MenuStore.url(inLibrary: location.url)) { [weak self] in
            Task { @MainActor in self?.loadFocus() }
        }
    }

    func stop() {
        watcher?.stop(); watcher = nil
        menuPresenter?.stop(); menuPresenter = nil
        syncTask?.cancel(); focusTask?.cancel()
    }

    func entry(id: String) -> IndexedItem? { byID[id] }
    func fileURL(for entry: IndexedItem) -> URL { folder.appendingPathComponent(entry.relativePath) }

    /// Foreground, pull to refresh: re-scan the files and re-read the pick.
    func refresh() {
        scheduleSync()
        loadFocus()
    }

    /// The reader wrote status or progress: show it in the queue now, without waiting for the watcher.
    func itemChanged() {
        reloadItems()
        scheduleSync()
    }

    private func scheduleSync() {
        guard let sync else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            let result: Result<SyncReport, Error> = await Task.detached { Result { try sync.sync() } }.value
            guard let self, !Task.isCancelled else { return }
            if case .failure(let e) = result { self.errorMessage = "Sync failed: \(e.localizedDescription)" }
            self.isIndexing = false
            self.reloadItems()
            self.onSynced()
        }
    }

    /// Reads `.deepwell/menu.json` (coordinated, so an evicted copy is downloaded first) off the main thread.
    private func loadFocus() {
        let folder = folder
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            let queue = await Task.detached { CurrentFocus.load(library: folder, items: []).queue }.value
            guard let self, !Task.isCancelled else { return }
            self.focus = CurrentFocus(queue: queue, items: self.allItems)
        }
    }

    private func reloadItems() {
        guard let index else { return }
        do {
            let list = try index.list()
            allItems = list.map(\.item)
            byID = Dictionary(list.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
            inProgress = list.filter { $0.item.status == .reading }
            focus = focus?.updating(items: allItems)
        } catch {
            errorMessage = "Query failed: \(error.localizedDescription)"
        }
    }
}

/// Calls `onChange` when the file at `url` is written by another process (iCloud delivering a new version).
/// The phone never writes menu.json, so every `presentedItemDidChange` is the Mac's write arriving.
final class SharedFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let onChange: @Sendable () -> Void

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        presentedItemURL = url
        self.onChange = onChange
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
        NSFileCoordinator.addFilePresenter(self)
    }

    func presentedItemDidChange() { onChange() }
    func presentedItemDidGain(_ version: NSFileVersion) { onChange() }
    func stop() { NSFileCoordinator.removeFilePresenter(self) }
}
