import Foundation
import Observation
import DeepwellModel
import DeepwellLibrary
import DeepwellIndex
import DeepwellMenu
import DeepwellMagazines
import DeepwellCuration
import DeepwellUI
import DeepwellNarration

/// The phone's view of the library: the per-device SQLite index (Application Support, built from the container and
/// kept current by `LibraryWatcher`'s NSMetadataQuery) and the Mac's pick from `.deepwell/menu.json` (read only).
@Observable
@MainActor
final class FocusLibrary {
    let location: LibraryLocation
    var folder: URL { location.url }

    /// nil until menu.json has been read once.
    private(set) var focus: CurrentFocus?

    // Library tab (ticket 19): the whole index, filtered and searched like the Mac's list.
    /// Full-text search over the per-device index (title, author, tags, body); empty lists everything.
    var searchText = "" { didSet { if searchText != oldValue { reloadLibrary() } } }
    var filter = ItemFilter() { didSet { if filter != oldValue { reloadLibrary() } } }
    private(set) var libraryItems: [IndexedItem] = []
    private(set) var tagSummaries: [TagSummary] = []
    private(set) var errorMessage: String?
    /// True until the first index sync after launch has finished: rows for items not indexed yet say "Loading".
    private(set) var isIndexing = true
    /// Ticket 20: issues handed to the Mac (a `.pending.json` marker) that have no articles yet: "Splitting on Mac".
    private(set) var pendingIssues: [PendingIssue] = []
    /// Ticket 17: how each Current Focus item's files stand on this device (kept downloaded for offline use), by item id.
    private(set) var pinStates: [String: OfflinePins.State] = [:]

    @ObservationIgnored private var byID: [String: IndexedItem] = [:]
    @ObservationIgnored private var allItems: [Item] = []
    @ObservationIgnored private var index: LibraryIndex?
    @ObservationIgnored private var sync: LibrarySync?
    @ObservationIgnored private var watcher: LibraryWatcher?
    @ObservationIgnored private var menuPresenter: SharedFilePresenter?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    @ObservationIgnored private var pinTask: Task<Void, Never>?
    @ObservationIgnored private var pinned: [OfflinePins.Pin] = []

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
            // Ticket 19: each version's tags are replayed through the tag-ops log first.
            var failures: [String] = []
            let ops = TagOpsLog(library: location.url).load()
            for url in urls {
                do { try ConflictResolver.resolve(url, tagOps: ops) } catch { failures.append(url.lastPathComponent) }
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
        syncTask?.cancel(); focusTask?.cancel(); pinTask?.cancel()
    }

    func entry(id: String) -> IndexedItem? { byID[id] }
    func fileURL(for entry: IndexedItem) -> URL { folder.appendingPathComponent(entry.relativePath) }

    /// Foreground, pull to refresh: re-scan the files and re-read the pick.
    func refresh() {
        scheduleSync()
        loadFocus()
        pinned = []   // ask iCloud again: it may have evicted something while the app was away
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
            self.loadPendingIssues()
            self.onSynced()
        }
    }

    /// Markers in `issues/` whose issue has no article in the index. Reading a marker evicted on this device downloads
    /// it (it's tiny); without it the row still shows, titled by the file name.
    private func loadPendingIssues() {
        let folder = folder
        let split = Set(allItems.compactMap(\.issueID))
        Task { [weak self] in
            let list = await Task.detached { () -> [PendingIssue] in
                PendingIssue.markerIDs(inLibrary: folder).filter { !split.contains($0) }.map { id in
                    PendingIssue.read(issueID: id, inLibrary: folder)
                        ?? PendingIssue(issueID: id, file: id, title: IssueStore.url(for: id, in: folder)?
                            .deletingPathExtension().lastPathComponent ?? "Magazine issue")
                }
            }.value
            self?.pendingIssues = list.sorted { ($0.sharedAt ?? .distantPast) > ($1.sharedAt ?? .distantPast) }
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
            self.pinFocus()
        }
    }

    /// Offline pinning (ticket 17): when the queue (menu.json) or the items' paths change, asks iCloud to download each
    /// queue item's `.md` and `.narration/` folder, then checks back (3 s, backing off to a minute) until all are local,
    /// asking again for anything still not downloading. iOS has no API to stop it evicting them later; each change,
    /// foreground and pull to refresh asks again.
    private func pinFocus() {
        let pins = OfflinePins.pins(queue: focus?.queue, relativePaths: byID.mapValues(\.relativePath), library: folder)
        guard pins != pinned else { return }
        pinned = pins
        pinTask?.cancel()
        guard !pins.isEmpty else { pinStates = [:]; return }
        pinTask = Task { [weak self] in
            var delay: Double = 3
            var ask = pins
            while !Task.isCancelled {
                let request = ask
                let states = await Task.detached { () -> [String: OfflinePins.State] in
                    request.forEach { OfflinePins.request($0) }
                    return Dictionary(pins.map { ($0.itemID, OfflinePins.state(of: $0)) }, uniquingKeysWith: { a, _ in a })
                }.value
                guard let self, !Task.isCancelled else { return }
                self.pinStates = states
                ask = pins.filter { states[$0.itemID] == .notDownloaded }
                guard states.values.contains(where: { $0 != .downloaded }) else { return }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(60, delay * 2)
            }
        }
    }

    private func reloadItems() {
        guard let index else { return }
        do {
            let list = try index.list()
            allItems = list.map(\.item)
            byID = Dictionary(list.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
            focus = focus?.updating(items: allItems)
            pinFocus()
        } catch {
            errorMessage = "Query failed: \(error.localizedDescription)"
        }
        reloadLibrary()
    }

    /// The Library tab's rows and the tag list, from the index (`search` lists everything for an empty query).
    private func reloadLibrary() {
        guard let index else { return }
        do {
            tagSummaries = try index.tagSummaries()
            if let tag = filter.tag, !tagSummaries.contains(where: { $0.name == tag }) { filter.tag = nil; return }
            libraryItems = try index.search(searchText, filter: filter)
        } catch {
            errorMessage = "Query failed: \(error.localizedDescription)"
        }
    }
}

extension FocusLibrary: TagsModel {
    /// Tag curation on the phone (ticket 19): `TagCurator` appends the op to `.deepwell/tag-ops.jsonl` under this
    /// device's name, rewrites the affected files (coordinated) and refreshes their index rows.
    func curate(_ action: (TagCurator) throws -> CurationResult) {
        guard let index else { return }
        do {
            let result = try action(TagCurator(root: folder, index: index, device: SharedConfig.deviceName))
            errorMessage = result.failed.isEmpty ? nil
                : "\(result.failed.count) file(s) could not be updated: \(result.failed.keys.sorted().joined(separator: ", "))"
        } catch {
            errorMessage = "Tag change failed: \(error.localizedDescription)"
        }
        reloadItems()
    }

    /// "Show Items" in the tag list: the Library filtered to that tag.
    func showItems(tagged tag: String) {
        searchText = ""
        filter = ItemFilter(tag: tag)
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
