import Foundation
import Observation
import DeepwellModel
import DeepwellIndex
import DeepwellCuration

/// Glue between the library folder, the SQLite index and the views. All logic lives in DeepwellIndex.
@Observable
@MainActor
final class LibraryModel {
    private(set) var items: [IndexedItem] = []
    private(set) var errorMessage: String?
    var searchText = "" { didSet { reload() } }
    var typeFilter: ItemType? { didSet { reload() } }
    var statusFilter: ItemStatus? { didSet { reload() } }
    var tagFilter: String? { didSet { reload() } }
    private(set) var tagSummaries: [TagSummary] = []

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
        if let t = tagFilter, !tagSummaries.contains(where: { $0.name == t }) { tagFilter = nil }
    }

    func reportCurationError(_ message: String) { errorMessage = message; reload() }

    func rebuildIndex() { scheduleSync(rebuild: true) }

    func reload() {
        guard let index else { return }
        let filter = ItemFilter(type: typeFilter, status: statusFilter, tag: tagFilter)
        tagSummaries = (try? index.tagSummaries()) ?? tagSummaries
        do {
            items = searchText.trimmingCharacters(in: .whitespaces).isEmpty
                ? try index.list(filter: filter)
                : try index.search(searchText, filter: filter)
        } catch {
            errorMessage = "Query failed: \(error.localizedDescription)"
        }
    }
}
