import Foundation
import Observation
import DeepwellModel
import DeepwellIndex
import DeepwellCuration
import DeepwellUI

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
    private(set) var index: LibraryIndex?
    private var sync: LibrarySync?
    private var watcher: FolderWatcher?
    private nonisolated(unsafe) var accessing = false
    private var syncTask: Task<Void, Never>?

    init(folder: URL) {
        self.folder = folder
        accessing = folder.startAccessingSecurityScopedResource()
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
        watcher = FolderWatcher(url: folder) { [weak self] in
            Task { @MainActor in self?.scheduleSync() }
        }
    }

    deinit {
        if accessing { folder.stopAccessingSecurityScopedResource() }
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

    func makeCurator() -> TagCurator? { index.map { TagCurator(root: folder, index: $0) } }

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
    func curate(_ action: (TagCurator) throws -> CurationResult) {
        guard let curator = makeCurator() else { return }
        do {
            let result = try action(curator)
            reportCuration(result)
        } catch {
            reportCurationError("Tag change failed: \(error.localizedDescription)")
        }
    }

    func showItems(tagged tag: String) {
        searchText = ""
        section = .tag(tag)
    }
}
