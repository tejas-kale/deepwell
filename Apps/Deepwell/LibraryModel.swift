import Foundation
import Observation
import DeepwellModel
import DeepwellIndex
import DeepwellCuration
import DeepwellUI
import DeepwellLibrary

/// What the sidebar has selected. Current Focus is this week's bundle; the rest are views of all captures.
enum LibrarySection: Hashable {
    case focus
    case all
    case type(ItemType)
    case status(ItemStatus)
    case tag(String)

    var filter: ItemFilter {
        switch self {
        case .focus, .all: ItemFilter()
        case .type(let t): ItemFilter(type: t)
        case .status(let s): ItemFilter(status: s)
        case .tag(let t): ItemFilter(tag: t)
        }
    }
}

/// Glue between the library folder, the SQLite index and the views. All logic lives in DeepwellIndex.
@Observable
@MainActor
final class LibraryModel {
    private(set) var items: [IndexedItem] = []
    private(set) var errorMessage: String?
    var searchText = "" { didSet { reload() } }
    var section: LibrarySection = .focus { didSet { if section != oldValue { reload() } } }
    private(set) var tagSummaries: [TagSummary] = []
    /// Every indexed item, unfiltered, for sidebar counts and for opening items from the week's bundle.
    private(set) var allItems: [IndexedItem] = []
    private var byID: [String: IndexedItem] = [:]
    private var byPath: [String: IndexedItem] = [:]
    /// Bumped on every reload, so views can refresh things derived from item status (the week's progress).
    private(set) var revision = 0

    let folder: URL
    let location: LibraryLocation
    private(set) var index: LibraryIndex?
    private var sync: LibrarySync?
    private var watcher: LibraryWatcher?
    private var syncTask: Task<Void, Never>?

    /// `onLibraryChange`: after every settled burst of library changes (ticket 20 hands these to the split and
    /// transcription passes).
    init(location: LibraryLocation, onLibraryChange: @escaping @MainActor () -> Void = {}) {
        self.location = location
        self.folder = location.url
        do {
            let index = try LibraryIndex(url: LibraryIndex.defaultIndexURL())
            self.index = index
            self.sync = LibrarySync(root: folder, index: index)
        } catch {
            errorMessage = "Could not open the index: \(error.localizedDescription)"
            return
        }
        reload()
        scheduleSync()
        // NSMetadataQuery in the iCloud container (changes, downloads, conflicts), FSEvents in the local fallback.
        // `downloadsIssues`: magazine originals and markers handed over from the phone (ticket 20).
        watcher = LibraryWatcher(location: location, downloadsIssues: true, onChange: { [weak self] in
            Task { @MainActor in self?.scheduleSync(); onLibraryChange() }
        }, onConflicts: { [weak self] urls in
            // Already on a background queue: merge each item's conflict versions into the current file.
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
        })
    }

    func fileURL(for item: IndexedItem) -> URL { folder.appendingPathComponent(item.relativePath) }
    func entry(id: String) -> IndexedItem? { byID[id] }
    func entry(path: String) -> IndexedItem? { byPath[path] }
    func count(_ type: ItemType) -> Int { allItems.filter { $0.item.type == type }.count }
    func count(_ status: ItemStatus) -> Int { allItems.filter { $0.item.status == status }.count }

    /// Re-scan the folder off the main thread, then refresh the list.
    func scheduleSync(rebuild: Bool = false) {
        guard let sync else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            let result: Result<SyncReport, Error> = await Task.detached {
                Result { try rebuild ? sync.rebuild() : sync.sync() }
            }.value
            guard let self, !Task.isCancelled else { return }
            if case .failure(let e) = result { self.errorMessage = "Sync failed: \(e.localizedDescription)" }
            self.reload()
        }
    }

    /// Ops are recorded in `.deepwell/tag-ops.jsonl` under this Mac's name (ticket 19).
    func makeCurator() -> TagCurator? { index.map { TagCurator(root: folder, index: $0, device: SharedConfig.deviceName) } }

    func reportCuration(_ result: CurationResult) {
        errorMessage = result.failed.isEmpty ? nil
            : "\(result.failed.count) file(s) could not be updated: \(result.failed.keys.sorted().joined(separator: ", "))"
        reload()
        if case .tag(let t) = section, !tagSummaries.contains(where: { $0.name == t }) { section = .all }
    }

    func reportCurationError(_ message: String) { errorMessage = message; reload() }

    func rebuildIndex() { scheduleSync(rebuild: true) }

    func reload() {
        guard let index else { return }
        tagSummaries = (try? index.tagSummaries()) ?? tagSummaries
        do {
            allItems = try index.list()
            byID = Dictionary(allItems.map { ($0.item.id, $0) }, uniquingKeysWith: { a, _ in a })
            byPath = Dictionary(allItems.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
            let filter = section.filter
            items = searchText.trimmingCharacters(in: .whitespaces).isEmpty
                ? (filter == ItemFilter() ? allItems : try index.list(filter: filter))
                : try index.search(searchText, filter: filter)
        } catch {
            errorMessage = "Query failed: \(error.localizedDescription)"
        }
        revision += 1
    }
}

extension LibraryModel: TagsModel {
    /// Runs a tag curation action (file rewrites + index refresh in `TagCurator`), then refreshes the list.
    @discardableResult
    func curate(_ action: (TagCurator) throws -> CurationResult) -> CurationResult? {
        guard let curator = makeCurator() else { return nil }
        do {
            let result = try action(curator)
            reportCuration(result)
            return result
        } catch {
            reportCurationError("Tag change failed: \(error.localizedDescription)")
            return nil
        }
    }

    func showItems(tagged tag: String) {
        searchText = ""
        section = .tag(tag)
    }
}
